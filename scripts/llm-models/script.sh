#!/usr/bin/env bash
# LLM モデル一覧の共通スクリプト。
# backend 別の利用可能モデル一覧 llm-models.json（モデルごとのオブジェクトの配列）を作る。
# 各要素は backend・model・description（公式の1行説明）を持つ。claude は加えて、個別ページ
# 「How it compares」表の自モデル行の各値を、列名をキーにした comparison オブジェクトとして持つ。
# このスクリプト自身の場所にある llm-models.json とモデルキャッシュだけを管理し、LLM は一切使わない。
#
# 役割:
#   - llm-models.json の日次再生成（1日以上前/不在のときだけ作り直す。新しければ何もしない）
#   - モデルキャッシュ（codex: codex debug models / claude: 公式 docs Markdown）の取得
#     claude は overview に加え、overview の「Model page」行が指す各モデルの個別ページも取得する
#   - 退役済みモデルの除外
#
# description はキャッシュの公式説明文をそのまま入れる（要約しない）。
# 外部へ送るのは公開情報の取得のみで、鍵・本文は送らない。
#
# 失敗時: 再生成に失敗したら既存の一覧ファイル・キャッシュには触らず、非0で終了し、
#         stderr に失敗理由を1行出す。ファイル不在・古いままの扱いは利用側の責務とする。
#         claude の個別ページのどれかの取得・抽出に失敗した場合もこの扱いに従う。
set -euo pipefail

LLM_MODELS_MAX_AGE_SECONDS=86400 # 一覧・キャッシュの鮮度（1日）
LLM_MODELS_CLAUDE_MODELS_URL="https://platform.claude.com/docs/en/about-claude/models/overview.md" # claude モデルの公式 docs
LLM_MODELS_CLAUDE_MODELS_TIMEOUT=20 # claude モデルキャッシュ取得のタイムアウト（秒）

# このスクリプトの実体があるディレクトリ。symlink 経由で呼ばれても実体から解決する。
LLM_MODELS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_MODELS_FILE="$LLM_MODELS_DIR/llm-models.json"

# backend 別のモデルキャッシュは script.sh と同じディレクトリ直下に置く。
# claude は公式 docs Markdown、codex は JSON なので拡張子を分ける。
# claude の個別ページキャッシュも同じ直下に claude-model-<slug>-cache.md で置く。
llm_models_cache_file_for_backend() {
  case "$1" in
    claude) printf '%s/claude-models-cache.md\n' "$LLM_MODELS_DIR" ;;
    codex) printf '%s/codex-models-cache.json\n' "$LLM_MODELS_DIR" ;;
    *) printf 'error: unknown backend: %s\n' "$1" >&2; return 1 ;;
  esac
}

# claude 個別ページの URL（.../models/<slug>/overview）から slug を取り出す。
llm_models_claude_slug_from_url() {
  local u="${1%/overview}"
  printf '%s\n' "${u##*/}"
}

# claude 個別ページキャッシュのパス。
llm_models_claude_page_cache_file() {
  printf '%s/claude-model-%s-cache.md\n' "$LLM_MODELS_DIR" "$1"
}

llm_models_is_fresh() {
  local f="$1" now mtime
  [ -f "$f" ] || return 1
  now="$(date +%s)"
  mtime="$(date -r "$f" +%s 2>/dev/null)" || return 1
  [ "$((now - mtime))" -lt "$LLM_MODELS_MAX_AGE_SECONDS" ]
}

# codex のモデルキャッシュを取得する。取得できたときだけ tmp を本体に差し替える。
# 失敗したら既存キャッシュに触れず、理由を1行出して非0。
llm_models_refresh_codex_cache() {
  local cache_file="$1" tmp_file="$1.tmp" raw_file="$1.raw"

  if ! command -v jq >/dev/null 2>&1; then
    printf 'error: jq is required to normalize codex model cache\n' >&2
    return 1
  fi

  if ! codex debug models > "$raw_file"; then
    rm -f "$raw_file" "$tmp_file"
    printf 'error: failed to refresh codex model cache with official CLI command: codex debug models\n' >&2
    return 1
  fi

  if ! jq -e --arg fetched_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
      {
        backend: "codex",
        fetched_at: $fetched_at,
        source: "codex debug models",
        models: [ .models[] | select(.visibility == "list") ]
      }
    ' "$raw_file" > "$tmp_file"; then
    rm -f "$raw_file" "$tmp_file"
    printf 'error: failed to parse codex model catalog\n' >&2
    return 1
  fi

  rm -f "$raw_file"
  mv "$tmp_file" "$cache_file"
}

# 公開 docs の Markdown を1本取得して dest に差し替える。取得できたときだけ差し替える。
# 失敗（取得不可・空応答）したら既存ファイルに触れず、理由を1行出して非0。
llm_models_fetch_md() {
  local url="$1" dest="$2" tmp_file="$2.tmp"
  if ! curl -fsSL --max-time "$LLM_MODELS_CLAUDE_MODELS_TIMEOUT" "$url" > "$tmp_file"; then
    rm -f "$tmp_file"
    printf 'error: failed to fetch claude model docs markdown: %s\n' "$url" >&2
    return 1
  fi
  if [ ! -s "$tmp_file" ]; then
    rm -f "$tmp_file"
    printf 'error: claude model docs markdown returned an empty response: %s\n' "$url" >&2
    return 1
  fi
  mv "$tmp_file" "$dest"
}

# overview キャッシュから「Model page」行が指す各モデルの個別ページ URL を列挙する。
# 比較表の「Model page」行に載っているモデルだけが対象（本文中の旧モデルリンクは対象外）。
llm_models_claude_model_page_urls() {
  awk -F'|' '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^[ \t]*\|/ {
      if (tolower(trim($2)) == "model page") {
        for (c = 3; c <= NF; c++) {
          line = $c
          while (match(line, /\]\([^)]*\)/)) {
            print substr(line, RSTART + 2, RLENGTH - 3)
            line = substr(line, RSTART + RLENGTH)
          }
        }
        exit
      }
    }
  ' "$1"
}

# claude 個別ページ1枚から "model_id<TAB>description<TAB>label<TAB>value<TAB>..." を1行抽出する。
# model: `Model ID: `...`` の値。
# description: 冒頭の1行説明（公式の1行説明。比較表の値は含めない）。
# 以降は「How it compares」表の「(this model)」行の各値を label<TAB>value のペアで並べる
# （Model 名の列は除く）。列名は比較表のヘッダ行から取る。
# 値・説明・列名に含まれるタブは空白に潰し、タブ区切りが崩れないようにする。
# 構造が想定と違い Model ID が取れない場合は非0（fail-closed）。
llm_models_claude_extract_row() {
  awk '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function strip_links(s,  out, txt){
      out = s
      while (match(out, /\[[^]]*\]\([^)]*\)/)) {
        txt = substr(out, RSTART, RLENGTH); sub(/^\[/, "", txt); sub(/\].*/, "", txt)
        out = substr(out, 1, RSTART - 1) txt substr(out, RSTART + RLENGTH)
      }
      return out
    }
    BEGIN { id = ""; got = 0; desc = ""; inc = 0; haveheader = 0; pairs = "" }
    # Model ID 行。ここまでに拾った最後の素の行を1行説明とする。
    got == 0 && /^Model ID:/ {
      s = $0; sub(/^Model ID:[ \t]*/, "", s); gsub(/`/, "", s); id = trim(s); got = 1; next
    }
    # Model ID より前の素のテキスト行（見出し・表・箇条書き・太字注記を除く）を説明候補にする。
    got == 0 {
      t = trim($0)
      if (t != "" && t !~ /^\*\*/ && t !~ /^#/ && t !~ /^\|/ && t !~ /^-/) desc = t
      next
    }
    /^##[ \t]/ { inc = ($0 ~ /How it compares/) ? 1 : 0; next }
    inc == 1 && /^[ \t]*\|/ {
      if ($0 ~ /^[ \t]*\|[ :|-]+$/) next
      nf = split($0, a, "|")   # a[1] と a[nf] は先頭/末尾 | の外側で空。セルは a[2..nf-1]。
      if (haveheader == 0) {
        for (i = 2; i < nf; i++) { label[i] = strip_links(trim(a[i])); gsub(/\t/, " ", label[i]) }
        haveheader = 1
        next
      }
      if ($0 ~ /\(this model\)/) {
        for (i = 3; i < nf; i++) {   # i=2 は Model 名の列なので比較値に含めない
          v = strip_links(trim(a[i]))
          if (v == "") continue
          gsub(/\t/, " ", v)
          pairs = pairs "\t" label[i] "\t" v
        }
      }
      next
    }
    END {
      if (id == "") exit 1
      gsub(/\t/, " ", desc)
      print id "\t" desc pairs
    }
  ' "$1"
}

# claude のキャッシュ群（overview ＋ 個別ページ）を1日鮮度で確保する。
# overview を確保し、「Model page」行の各 URL について <url>.md を確保する。
# いずれかの取得に失敗したら既存キャッシュに触れず、理由を1行出して非0（fail-closed）。
llm_models_refresh_claude_caches() {
  local overview_cache="$1" url slug page_cache
  if ! llm_models_is_fresh "$overview_cache"; then
    llm_models_fetch_md "$LLM_MODELS_CLAUDE_MODELS_URL" "$overview_cache" || return 1
  fi
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    slug="$(llm_models_claude_slug_from_url "$url")"
    if [ -z "$slug" ]; then
      printf 'error: cannot derive claude model slug from model page url: %s\n' "$url" >&2
      return 1
    fi
    page_cache="$(llm_models_claude_page_cache_file "$slug")"
    if ! llm_models_is_fresh "$page_cache"; then
      llm_models_fetch_md "$url.md" "$page_cache" || return 1
    fi
  done < <(llm_models_claude_model_page_urls "$overview_cache")
}

# backend のキャッシュを1日鮮度で確保する。新しければそのまま、古い/不在なら再取得する。
# 再取得に失敗したら既存キャッシュに触れず非0（fail-closed）。
llm_models_ensure_cache() {
  local backend="$1" cache_file
  cache_file="$(llm_models_cache_file_for_backend "$backend")"
  case "$backend" in
    codex)
      llm_models_is_fresh "$cache_file" && return 0
      llm_models_refresh_codex_cache "$cache_file"
      ;;
    claude)
      # 個別ページごとに鮮度を見るため overview の鮮度では早期 return しない。
      llm_models_refresh_claude_caches "$cache_file"
      ;;
    *) printf 'error: unknown backend: %s\n' "$backend" >&2; return 1 ;;
  esac
}

# キャッシュから退役していない利用可能モデルを backend ごとのオブジェクト（1行1 JSON）で列挙する。
# 各オブジェクトは backend・model・description を持つ。description は公式の1行説明をそのまま使う
# （codex は description、claude は個別ページ冒頭の1行説明）。claude は加えて比較表の自モデル行の
# 各値を列名キーの comparison オブジェクトとして持つ。
# claude は個別ページの取得・抽出に失敗したら非0（fail-closed）。
llm_models_catalog_rows() {
  local backend="$1" cache_file
  cache_file="$(llm_models_cache_file_for_backend "$backend")"
  [ -f "$cache_file" ] || return 1
  case "$backend" in
    codex)
      jq -c '
        .models[]
        | select(
            type == "string"
            or (.upgrade.retirement_at == null)
            or (((.upgrade.retirement_at | fromdateiso8601?) // 0) > now)
          )
        | if type == "string" then { backend: "codex", model: ., description: "" }
          else { backend: "codex", model: .slug, description: ((.description // "") | gsub("[\t\n]"; " ")) } end
      ' "$cache_file"
      ;;
    claude)
      # overview の「Model page」行 → 各個別ページ .md の2段で組み立てる。
      local urls url slug page_cache row
      urls="$(llm_models_claude_model_page_urls "$cache_file")" || return 1
      if [ -z "$urls" ]; then
        printf 'error: no model page links found in claude overview cache: %s\n' "$cache_file" >&2
        return 1
      fi
      while IFS= read -r url; do
        [ -n "$url" ] || continue
        slug="$(llm_models_claude_slug_from_url "$url")"
        page_cache="$(llm_models_claude_page_cache_file "$slug")"
        if [ ! -f "$page_cache" ]; then
          printf 'error: claude per-model page cache is missing: %s\n' "$page_cache" >&2
          return 1
        fi
        if ! row="$(llm_models_claude_extract_row "$page_cache")"; then
          printf 'error: failed to extract model row from claude per-model page: %s\n' "$page_cache" >&2
          return 1
        fi
        # "model<TAB>description<TAB>label<TAB>value<TAB>..." を JSON オブジェクト1件にする。
        # 3列目以降の label/value ペアを列名順のまま comparison オブジェクトにまとめる。
        printf '%s\n' "$row" | jq -R -c '
          split("\t")
          | { backend: "claude", model: .[0], description: .[1] }
          + { comparison: ( .[2:] as $p
              | reduce range(0; ($p | length); 2) as $i ({}; . + { ($p[$i]): $p[$i + 1] }) ) }
        '
      done <<< "$urls"
      ;;
    *) printf 'error: unknown backend: %s\n' "$backend" >&2; return 1 ;;
  esac
}

# llm-models.json を再生成する。backend ごとにキャッシュを確保し、退役していないモデルを列挙する。
# いずれかの backend でキャッシュ確保か列挙に失敗したら既存を保持したまま非0（fail-closed）。
# 列挙結果（1行1 JSON オブジェクト）を tmp に集め、全 backend 成功時だけ配列にして本体へ差し替える。
llm_models_rebuild() {
  local backends=("$@")
  local tmp tmp_json backend rows any=0
  tmp="$(mktemp)"
  for backend in "${backends[@]}"; do
    if ! llm_models_ensure_cache "$backend"; then
      rm -f "$tmp"
      return 1
    fi
    # 列挙の失敗を取りこぼさないよう、exit code を捕捉してから流し込む。
    if ! rows="$(llm_models_catalog_rows "$backend")"; then
      rm -f "$tmp"
      return 1
    fi
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows" >> "$tmp"
      any=1
    fi
  done
  if [ "$any" -eq 0 ]; then
    rm -f "$tmp"
    printf 'error: cannot build llm-models because no models were enumerated from any backend\n' >&2
    return 1
  fi
  # 1行1オブジェクトの NDJSON を配列にまとめる。失敗したら本体に触れず非0。
  tmp_json="$tmp.json"
  if ! jq -s '.' "$tmp" > "$tmp_json"; then
    rm -f "$tmp" "$tmp_json"
    printf 'error: failed to assemble llm-models json array\n' >&2
    return 1
  fi
  rm -f "$tmp"
  mv "$tmp_json" "$LLM_MODELS_FILE"
}

# 起動時処理: 一覧が1日以上前（または不在）なら両 backend で再生成する。新しければ何もしない。
# 再生成に失敗したら既存の一覧・キャッシュに触れず非0で終了する。
llm_models_main() {
  if llm_models_is_fresh "$LLM_MODELS_FILE"; then
    printf 'llm-models: fresh (%s); nothing to do\n' "$(date -r "$LLM_MODELS_FILE" '+%Y-%m-%d')" >&2
    return 0
  fi

  if ! llm_models_rebuild codex claude; then
    printf 'error: failed to rebuild %s; existing list and cache left untouched\n' "$LLM_MODELS_FILE" >&2
    return 1
  fi
  printf 'llm-models: rebuilt %s\n' "$LLM_MODELS_FILE" >&2
}

llm_models_main

#!/usr/bin/env bash
# LLM モデル一覧の共通スクリプト。
# backend 別の利用可能モデル一覧 llm-models.tsv（backend<TAB>model<TAB>description）を作る。
# このスクリプト自身の場所にある llm-models.tsv とモデルキャッシュだけを管理し、LLM は一切使わない。
#
# 役割:
#   - llm-models.tsv の日次再生成（1日以上前/不在のときだけ作り直す。新しければ何もしない）
#   - モデルキャッシュ（codex: codex debug models / claude: 公式 docs Markdown）の取得
#   - 退役済みモデルの除外
#
# description はキャッシュの公式説明文をそのまま入れる（要約しない）。
# 外部へ送るのは公開情報の取得のみで、鍵・本文は送らない。
#
# 失敗時: 再生成に失敗したら既存の一覧ファイル・キャッシュには触らず、非0で終了し、
#         stderr に失敗理由を1行出す。ファイル不在・古いままの扱いは利用側の責務とする。
set -euo pipefail

LLM_MODELS_MAX_AGE_SECONDS=86400 # 一覧・キャッシュの鮮度（1日）
LLM_MODELS_CLAUDE_MODELS_URL="https://platform.claude.com/docs/en/about-claude/models/overview.md" # claude モデルの公式 docs
LLM_MODELS_CLAUDE_MODELS_TIMEOUT=20 # claude モデルキャッシュ取得のタイムアウト（秒）

# このスクリプトの実体があるディレクトリ。symlink 経由で呼ばれても実体から解決する。
LLM_MODELS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_MODELS_FILE="$LLM_MODELS_DIR/llm-models.tsv"

# backend 別のモデルキャッシュは script.sh と同じディレクトリ直下に置く。
# claude は公式 docs Markdown、codex は JSON なので拡張子を分ける。
llm_models_cache_file_for_backend() {
  case "$1" in
    claude) printf '%s/claude-models-cache.md\n' "$LLM_MODELS_DIR" ;;
    codex) printf '%s/codex-models-cache.json\n' "$LLM_MODELS_DIR" ;;
    *) printf 'error: unknown backend: %s\n' "$1" >&2; return 1 ;;
  esac
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

# claude のモデルキャッシュ（公式 docs Markdown）を取得する。取得できたときだけ差し替える。
# 失敗したら既存キャッシュに触れず、理由を1行出して非0。
llm_models_refresh_claude_cache() {
  local cache_file="$1" tmp_file="$1.tmp"
  local url="$LLM_MODELS_CLAUDE_MODELS_URL"

  if ! curl -fsSL --max-time "$LLM_MODELS_CLAUDE_MODELS_TIMEOUT" "$url" > "$tmp_file"; then
    rm -f "$tmp_file"
    printf 'error: failed to refresh claude model cache from public official docs: %s\n' "$url" >&2
    return 1
  fi
  if [ ! -s "$tmp_file" ]; then
    rm -f "$tmp_file"
    printf 'error: claude model cache refresh returned an empty response: %s\n' "$url" >&2
    return 1
  fi
  mv "$tmp_file" "$cache_file"
}

# backend のキャッシュを1日鮮度で確保する。新しければそのまま、古い/不在なら再取得する。
# 再取得に失敗したら既存キャッシュに触れず非0（fail-closed）。
llm_models_ensure_cache() {
  local backend="$1" cache_file
  cache_file="$(llm_models_cache_file_for_backend "$backend")"
  if llm_models_is_fresh "$cache_file"; then
    return 0
  fi
  case "$backend" in
    codex) llm_models_refresh_codex_cache "$cache_file" ;;
    claude) llm_models_refresh_claude_cache "$cache_file" ;;
    *) printf 'error: unknown backend: %s\n' "$backend" >&2; return 1 ;;
  esac
}

# キャッシュから退役していない利用可能モデルを "model<TAB>description" で列挙する。
# description は公式説明文（codex は description / claude は比較表の属性連結）をそのまま使う。
llm_models_catalog_rows() {
  local backend="$1" cache_file
  cache_file="$(llm_models_cache_file_for_backend "$backend")"
  [ -f "$cache_file" ] || return 1
  case "$backend" in
    codex)
      jq -r '
        .models[]
        | select(
            type == "string"
            or (.upgrade.retirement_at == null)
            or (((.upgrade.retirement_at | fromdateiso8601?) // 0) > now)
          )
        | if type == "string" then "\(.)\t"
          else "\(.slug)\t\((.description // "") | gsub("[\t\n]"; " "))" end
      ' "$cache_file"
      ;;
    claude)
      # 公式 docs Markdown のモデル比較表は「列=モデル / 行=属性」。
      # 「Claude API ID」行から各列のモデル id を取り、その列の他属性を
      # 「属性: 値」で連結して description にする。退役言及の行は除く。
      # 表が想定の形式でない（ID 行が無い）場合は何も出さない。
      awk -F'|' '
        function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function delink(s,  m, txt){
          while (match(s, /\[[^]]*\]\([^)]*\)/)) {
            m = substr(s, RSTART, RLENGTH); txt = m
            sub(/^\[/, "", txt); sub(/\].*/, "", txt)
            s = substr(s, 1, RSTART - 1) txt substr(s, RSTART + RLENGTH)
          }
          return s
        }
        /^[ \t]*\|/ {
          if ($0 ~ /^[ \t]*\|[ :|-]+$/) next
          nr++
          labels[nr] = delink(trim($2))
          ncol = NF - 1
          for (c = 3; c <= ncol; c++) cell[nr, c] = delink(trim($c))
          if (tolower(labels[nr]) ~ /claude api id/) idrow = nr
          next
        }
        END {
          if (idrow == "") exit
          for (c = 3; c <= ncol; c++) {
            id = cell[idrow, c]; gsub(/`/, "", id)
            if (id == "") continue
            desc = ""
            for (r = 2; r <= nr; r++) {
              if (r == idrow || labels[r] == "") continue
              if (tolower(labels[r]) ~ /deprecat|retir/) continue
              v = cell[r, c]; if (v == "") continue
              desc = desc (desc == "" ? "" : "; ") labels[r] ": " v
            }
            gsub(/\t/, " ", desc)
            print id "\t" desc
          }
        }
      ' "$cache_file"
      ;;
    *) printf 'error: unknown backend: %s\n' "$backend" >&2; return 1 ;;
  esac
}

# llm-models.tsv を再生成する。backend ごとにキャッシュを確保し、退役していないモデルを列挙する。
# いずれかの backend でキャッシュ確保か列挙に失敗したら既存を保持したまま非0（fail-closed）。
# 一覧は tmp に組み立て、全 backend 成功時だけ本体へ差し替える。
llm_models_rebuild() {
  local backends=("$@")
  local tmp backend model desc any=0
  tmp="$(mktemp)"
  printf '# backend\tmodel\tdescription\n' > "$tmp"
  for backend in "${backends[@]}"; do
    if ! llm_models_ensure_cache "$backend"; then
      rm -f "$tmp"
      return 1
    fi
    while IFS=$'\t' read -r model desc; do
      [ -n "$model" ] || continue
      printf '%s\t%s\t%s\n' "$backend" "$model" "$desc" >> "$tmp"
      any=1
    done < <(llm_models_catalog_rows "$backend")
  done
  if [ "$any" -eq 0 ]; then
    rm -f "$tmp"
    printf 'error: cannot build llm-models because no models were enumerated from any backend\n' >&2
    return 1
  fi
  mv "$tmp" "$LLM_MODELS_FILE"
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

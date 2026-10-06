#!/usr/bin/env bash
# model-tiers スキルの実行基盤。
# 委譲先モデル一覧 model-tiers.tsv（backend<TAB>model<TAB>summary）の鮮度判定と再生成を担う。
# このスキルは完全に独立しており、他スキルを参照せず自スキル配下だけで完結する。
#
# 役割:
#   - model-tiers.tsv の日次再生成（1日以上前/不在のときだけ作り直す）
#   - モデルキャッシュ（codex: codex debug models / claude: 公式 docs Markdown）の管理
#   - 各モデルの1行要約を設定から隔離した claude -p --model haiku で作成
#
# 接続先は api.typesafe.ai 等の外部に鍵・本文を送らない。要約には隔離した claude を使う。
set -euo pipefail

DELEGATE_MAX_AGE_SECONDS="${DELEGATE_MAX_AGE_SECONDS:-86400}" # model-tiers・キャッシュの鮮度（1日）
DELEGATE_SUMMARY_MODEL="${DELEGATE_SUMMARY_MODEL:-haiku}"

delegate_state_dir() {
  local project_dir="${AGENT_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
  if [ -z "$project_dir" ]; then
    project_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || true
  fi
  if [ -z "$project_dir" ]; then
    printf 'error: unable to resolve project root from AGENT_PROJECT_DIR, CLAUDE_PROJECT_DIR, or the current git repository\n' >&2
    return 1
  fi
  printf '%s/state/delegate\n' "$project_dir"
}

delegate_cache_dir() {
  if [ -n "${DELEGATE_MODEL_CACHE_DIR:-}" ]; then
    printf '%s\n' "$DELEGATE_MODEL_CACHE_DIR"
    return 0
  fi
  local state_dir
  state_dir="$(delegate_state_dir)" || return 1
  printf '%s/.model-cache\n' "$state_dir"
}

delegate_cache_file_for_backend() {
  local backend="$1" cache_dir
  cache_dir="$(delegate_cache_dir)" || return 1
  printf '%s/%s-models.json\n' "$cache_dir" "$backend"
}

delegate_is_fresh() {
  local f="$1" now mtime
  [ -f "$f" ] || return 1
  now="$(date +%s)"
  mtime="$(date -r "$f" +%s 2>/dev/null)" || return 1
  [ "$((now - mtime))" -lt "$DELEGATE_MAX_AGE_SECONDS" ]
}

delegate_refresh_codex_cache() {
  local cache_file="$1" tmp_file="$1.tmp" raw_file="$1.raw"
  local cmd="${DELEGATE_CODEX_MODELS_CMD:-codex debug models}"

  if ! command -v jq >/dev/null 2>&1; then
    printf 'error: jq is required to normalize codex model cache\n' >&2
    return 1
  fi

  mkdir -p "$(dirname "$cache_file")"
  if ! bash -c "$cmd" > "$raw_file"; then
    rm -f "$raw_file" "$tmp_file"
    printf 'error: failed to refresh codex model cache with official CLI command: %s\n' "$cmd" >&2
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

delegate_refresh_claude_cache() {
  local cache_file="$1" tmp_file="$1.tmp"
  local url="${DELEGATE_CLAUDE_MODELS_URL:-https://platform.claude.com/docs/en/about-claude/models/overview.md}"

  mkdir -p "$(dirname "$cache_file")"
  if ! curl -fsSL --max-time "${DELEGATE_CLAUDE_MODELS_TIMEOUT:-20}" "$url" > "$tmp_file"; then
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

# backend のキャッシュを1日鮮度で確保する。再取得に失敗しても既存キャッシュがあれば続行。
# キャッシュが使える状態なら 0、1件も無ければ 1。
delegate_try_cache() {
  local backend="$1" cache_file rc=0
  cache_file="$(delegate_cache_file_for_backend "$backend")" || return 1
  if delegate_is_fresh "$cache_file"; then
    return 0
  fi
  case "$backend" in
    codex) delegate_refresh_codex_cache "$cache_file" || rc=$? ;;
    claude) delegate_refresh_claude_cache "$cache_file" || rc=$? ;;
    *) return 1 ;;
  esac
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ -f "$cache_file" ]; then
    printf 'warning: delegate %s model cache refresh failed; using stale cache from %s\n' \
      "$backend" "$(date -r "$cache_file" '+%Y-%m-%d')" >&2
    return 0
  fi
  return 1
}

# キャッシュから退役していない利用可能モデルを "model<TAB>description" で列挙する。
delegate_catalog_rows() {
  local backend="$1" cache_file
  cache_file="$(delegate_cache_file_for_backend "$backend")" || return 1
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
    *) return 1 ;;
  esac
}

# 要約専用に claude を隔離実行する。呼び出し元プロジェクトの設定・hooks・MCP ツール・
# CLAUDE.md を読み込ませない（空の作業ディレクトリ・setting-sources なし・strict-mcp-config）。
delegate_summary_llm() {
  local prompt="$1" workdir rc
  workdir="$(mktemp -d)" || return 1
  ( cd "$workdir" && claude -p "$prompt" --model "$DELEGATE_SUMMARY_MODEL" \
      --setting-sources '' --strict-mcp-config < /dev/null 2>/dev/null )
  rc=$?
  rmdir "$workdir" 2>/dev/null || true
  return "$rc"
}

# 応答が1行要約として妥当か判定する。空・複数行・長すぎ・拒否文は不正（非0）。
delegate_summary_ok() {
  local raw="$1"
  [ -n "$raw" ] || return 1
  case "$raw" in *$'\n'*) return 1 ;; esac
  [ "${#raw}" -le 120 ] || return 1
  case "$raw" in
    *申し訳*|*できません*|*ありません*|*わかりません*|*知識*) return 1 ;;
  esac
  return 0
}

# モデル1件の1行要約を隔離した claude -p --model haiku で作る。
# 根拠はキャッシュの説明文（参考情報）だけに限る。応答が要約として不正なら description を使う。
delegate_summarize_model() {
  local backend="$1" model="$2" desc="$3" raw="" out=""
  if [ "${DELEGATE_SKIP_LLM:-}" != "1" ]; then
    raw="$(delegate_summary_llm "次のモデルの用途・特徴を、与えた参考情報だけを根拠に日本語で簡潔に1行（60文字以内）で説明してください。あなた自身の知識で補わず、参考情報が乏しくても推測で補足しないこと。説明文のみを返し、改行や箇条書きを含めないこと。backend=${backend} model=${model} 参考情報=${desc}")" || raw=""
    if delegate_summary_ok "$raw"; then
      out="$(printf '%s' "$raw" | tr '\n' ' ' | sed 's/\t/ /g; s/  */ /g; s/^ //; s/ $//')"
    fi
  fi
  if [ -z "$out" ]; then
    out="$(printf '%s' "$desc" | tr '\n' ' ' | sed 's/\t/ /g; s/  */ /g; s/^ //; s/ $//')"
  fi
  [ -n "$out" ] || out="$model"
  printf '%s\n' "$out"
}

# model-tiers.tsv を再生成する。backend ごとにキャッシュを確保して退役していないモデルを列挙し、
# 各モデルの1行要約を付ける。1件のキャッシュも無ければ fail-closed（非0）。
delegate_rebuild_model_tiers() {
  local tiers_file="$1"; shift
  local backends=("$@")
  local tmp backend model desc summary any=0
  tmp="$(mktemp)"
  printf '# backend\tmodel\tsummary\n' > "$tmp"
  for backend in "${backends[@]}"; do
    delegate_try_cache "$backend" || continue
    while IFS=$'\t' read -r model desc; do
      [ -n "$model" ] || continue
      summary="$(delegate_summarize_model "$backend" "$model" "$desc")"
      printf '%s\t%s\t%s\n' "$backend" "$model" "$summary" >> "$tmp"
      any=1
    done < <(delegate_catalog_rows "$backend")
  done
  if [ "$any" -eq 0 ]; then
    rm -f "$tmp"
    printf 'error: delegate cannot rebuild model-tiers because no model cache is available\n' >&2
    return 1
  fi
  mkdir -p "$(dirname "$tiers_file")"
  mv "$tmp" "$tiers_file"
}

# 起動時処理: model-tiers が1日以上前（または不在）なら両 backend で再生成し、
# 新しければ何もしない。model-tiers が利用可能なら 0、無く再生成も失敗したら 1（fail-closed）。
delegate_refresh_model_tiers() {
  local state_dir tiers_file
  state_dir="$(delegate_state_dir)" || return 1
  tiers_file="$state_dir/model-tiers.tsv"

  if delegate_is_fresh "$tiers_file"; then
    printf 'model-tiers: fresh (%s); nothing to do\n' "$(date -r "$tiers_file" '+%Y-%m-%d')" >&2
    return 0
  fi

  if ! delegate_rebuild_model_tiers "$tiers_file" codex claude; then
    [ -f "$tiers_file" ] && return 0
    return 1
  fi
  printf 'model-tiers: rebuilt %s\n' "$tiers_file" >&2
  return 0
}

delegate_refresh_model_tiers

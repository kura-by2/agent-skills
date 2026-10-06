#!/usr/bin/env bash
# delegate-impl / delegate-sub / delegate-review 各スキルに同梱する実行基盤。
# 各スキルは完全に独立しており、このファイルは他スキルを参照せず自スキル配下だけで完結する。
#
# 役割:
#   - model-tiers.tsv（backend<TAB>model<TAB>summary）の日次再生成
#   - エージェント別フォールバック fallback/<agent>.tsv（backend<TAB>model）の生成
#   - 委譲ごとの Jev によるモデル判定（本文は送らず要約のみ）
#   - モデルキャッシュ（codex: codex debug models / claude: 公式 docs Markdown）の管理
#   - codex / claude（agent 指定）での委譲実行
#
# 接続先は api.typesafe.ai に固定する。鍵の値と指示ファイル本文はログ・出力に書かない。

DELEGATE_MAX_AGE_SECONDS="${DELEGATE_MAX_AGE_SECONDS:-86400}" # model-tiers・キャッシュの鮮度（1日）
DELEGATE_JEV_URL="https://api.typesafe.ai/v1/systemone"      # 固定（上書き不可）
DELEGATE_JEV_MODEL="jev-latest"
DELEGATE_JEV_TIMEOUT="${DELEGATE_JEV_TIMEOUT:-3}"
DELEGATE_JEV_CONFIDENCE_MIN="0.6"
DELEGATE_SUMMARY_MODEL="${DELEGATE_SUMMARY_MODEL:-haiku}"

delegate_mark_sync_deadline_delegate() {
  local session="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$session" ] || return 0
  mkdir -p /tmp/claude-sync-deadline 2>/dev/null || return 0
  : > "/tmp/claude-sync-deadline/$session.delegate" 2>/dev/null || true
}

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
      # 公式 docs Markdown は非構造。モデル id を拾い、退役言及のある行は除く。
      # description はその id が最初に現れた行のテキストを使う。
      awk '
        {
          line = $0
          if (tolower(line) ~ /deprecat|retir/) next
          while (match(line, /claude-[a-z]+-[0-9]+(-[0-9]+)?/)) {
            id = substr(line, RSTART, RLENGTH)
            if (!(id in seen)) {
              seen[id] = 1
              desc = $0
              gsub(/\t/, " ", desc)
              print id "\t" desc
            }
            line = substr(line, RSTART + RLENGTH)
          }
        }
      ' "$cache_file"
      ;;
    *) return 1 ;;
  esac
}

# モデル1件の1行要約を claude -p --model haiku で作る。失敗・空なら description を使う。
delegate_summarize_model() {
  local backend="$1" model="$2" desc="$3" out=""
  if [ "${DELEGATE_SKIP_LLM:-}" != "1" ]; then
    out="$(claude -p "次のモデルの用途・特徴を日本語で簡潔に1行（60文字以内）で説明してください。説明文のみを返し、改行や箇条書きを含めないこと。backend=${backend} model=${model} 参考情報=${desc}" \
      --model "$DELEGATE_SUMMARY_MODEL" < /dev/null 2>/dev/null \
      | tr '\n' ' ' | sed 's/\t/ /g; s/  */ /g; s/^ //; s/ $//')" || out=""
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

# model-tiers から指定 backend 群の model->summary を JSON object にする（Jev の criteria）。
delegate_criteria_json() {
  local tiers_file="$1"; shift
  local filter
  filter="$(printf '%s|' "$@")"
  awk -F '\t' -v f="$filter" '
    BEGIN { n = split(f, a, "|") }
    $0 !~ /^#/ && NF >= 3 {
      ok = 0
      for (i = 1; i <= n; i++) if ($1 == a[i] && a[i] != "") ok = 1
      if (ok) print $2 "\t" $3
    }
  ' "$tiers_file" | jq -R -s '
    split("\n") | map(select(length > 0) | split("\t")) | map({(.[0]): (.[1] // "")}) | add // {}
  '
}

# summary を state に、criteria を候補にして Jev の choice に問い合わせる。
# 標準出力に "choice<TAB>confidence"。鍵なし・criteria 空・HTTP 失敗・タイムアウト・解釈失敗は非0。
delegate_jev_choice() {
  local summary="$1" criteria_json="$2" instructions="$3"
  local key body resp
  key="${JEV_API_KEY:-}"
  [ -n "$key" ] || return 1
  [ -n "$criteria_json" ] && [ "$criteria_json" != "{}" ] || return 1
  body="$(jq -n --arg state "$summary" --arg model "$DELEGATE_JEV_MODEL" \
    --arg instr "$instructions" --argjson criteria "$criteria_json" '
    {
      state: $state,
      model: $model,
      questions: { route: { type: "choice", instructions: $instr, criteria: $criteria } }
    }')" || return 1
  resp="$(curl -fsS --max-time "$DELEGATE_JEV_TIMEOUT" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -X POST "$DELEGATE_JEV_URL" -d "$body" 2>/dev/null)" || return 1
  printf '%s' "$resp" | jq -e -r '
    .answers.route
    | select(.choice != null and (.confidence | type) == "number")
    | "\(.choice)\t\(.confidence)"
  ' 2>/dev/null
}

delegate_confidence_ok() {
  local conf="$1"
  [ -n "$conf" ] || return 1
  awk -v c="$conf" -v m="$DELEGATE_JEV_CONFIDENCE_MIN" 'BEGIN { exit !((c + 0) >= (m + 0)) }'
}

delegate_backend_from_model() {
  case "$1" in
    gpt-*) printf 'codex\n' ;;
    claude-*) printf 'claude\n' ;;
    *) return 1 ;;
  esac
}

# agent 用フォールバックを Jev で再生成する。backend ごとに1問判定して backend<TAB>model を書く。
# Jev が1行も返さなければ非0を返し、既存ファイルは上書きしない。
delegate_rebuild_fallback() {
  local tiers_file="$1" fallback_file="$2"; shift 2
  local backends=("$@")
  local tmp backend criteria out choice conf wrote=0
  tmp="$(mktemp)"
  for backend in "${backends[@]}"; do
    criteria="$(delegate_criteria_json "$tiers_file" "$backend")" || continue
    [ -n "$criteria" ] && [ "$criteria" != "{}" ] || continue
    out="$(delegate_jev_choice "作業全般に標準的に使うモデルを1つ選ぶ。" "$criteria" \
      "この backend の既定として最も適したモデルを選ぶ。")" || continue
    IFS=$'\t' read -r choice conf <<< "$out"
    [ -n "$choice" ] || continue
    printf '%s\t%s\n' "$backend" "$choice" >> "$tmp"
    wrote=1
  done
  if [ "$wrote" -eq 0 ]; then
    rm -f "$tmp"
    return 1
  fi
  mkdir -p "$(dirname "$fallback_file")"
  mv "$tmp" "$fallback_file"
}

# 起動時処理: model-tiers が1日以上前（または不在）なら両 backend で再生成し、
# 同時にこの agent のフォールバック（候補 backend 分）だけを作る。
# model-tiers が利用可能なら 0、無く再生成も失敗したら 1（fail-closed）。
delegate_refresh_tiers_and_fallback() {
  local agent="$1"; shift
  local fb_backends=("$@")
  local state_dir tiers_file fallback_file
  state_dir="$(delegate_state_dir)" || return 1
  tiers_file="$state_dir/model-tiers.tsv"
  fallback_file="$state_dir/fallback/$agent.tsv"

  if delegate_is_fresh "$tiers_file"; then
    return 0
  fi

  if ! delegate_rebuild_model_tiers "$tiers_file" codex claude; then
    [ -f "$tiers_file" ] && return 0
    return 1
  fi

  if ! delegate_rebuild_fallback "$tiers_file" "$fallback_file" "${fb_backends[@]}"; then
    printf 'warning: delegate could not rebuild fallback for %s via Jev (keeping existing)\n' "$agent" >&2
  fi
  return 0
}

# 指示ファイル本文を claude -p --model haiku で「作業の種類」だけの日本語1文に要約する。
# 固有名詞・パス・URL・鍵・コードを含めない。失敗・空は非0。
delegate_summarize_task() {
  local task_path="$1" out
  [ -f "$task_path" ] || return 1
  [ "${DELEGATE_SKIP_LLM:-}" != "1" ] || return 1
  out="$(claude -p "次の委譲指示を日本語1文で要約してください。出力は『どんな種類の作業か（作業の種類と対象の種別）』だけにし、固有名詞・ファイルパス・URL・識別子・鍵・コード・引用された文字列は一切含めないこと。要約文のみを返すこと。

$(cat "$task_path")" --model "$DELEGATE_SUMMARY_MODEL" < /dev/null 2>/dev/null \
    | tr '\n' ' ' | sed 's/\t/ /g; s/  */ /g; s/^ //; s/ $//')" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# fallback/<agent>.tsv から backend<TAB>model を1行取り出す。
# backend_filter を渡すとその backend の行だけ、省略すると1行目を返す。
delegate_fallback_model() {
  local agent="$1" backend_filter="${2:-}"
  local state_dir fallback_file backend model
  state_dir="$(delegate_state_dir)" || return 1
  fallback_file="$state_dir/fallback/$agent.tsv"
  [ -f "$fallback_file" ] || return 1
  while IFS=$'\t' read -r backend model; do
    [ -n "$backend" ] || continue
    case "$backend" in \#*) continue ;; esac
    if [ -n "$backend_filter" ] && [ "$backend" != "$backend_filter" ]; then
      continue
    fi
    [ -n "$model" ] || continue
    printf '%s\t%s\n' "$backend" "$model"
    return 0
  done < "$fallback_file"
  return 1
}

# agent 用に使用モデルを決める。標準出力 "backend<TAB>model"。
# 委譲ごとに Jev（要約→choice、閾値 0.6）で選び、鍵なし・失敗・低確信度・要約失敗は fallback へ倒す。
delegate_resolve_model() {
  local agent="$1" task_path="$2"; shift 2
  local backends=("$@")
  local state_dir tiers_file summary criteria out choice conf backend
  state_dir="$(delegate_state_dir)" || return 1
  tiers_file="$state_dir/model-tiers.tsv"

  if [ -f "$tiers_file" ] && [ -n "${JEV_API_KEY:-}" ]; then
    if summary="$(delegate_summarize_task "$task_path")"; then
      criteria="$(delegate_criteria_json "$tiers_file" "${backends[@]}")" || criteria="{}"
      if [ -n "$criteria" ] && [ "$criteria" != "{}" ]; then
        if out="$(delegate_jev_choice "$summary" "$criteria" "この作業に最も適したモデルを選ぶ。")"; then
          IFS=$'\t' read -r choice conf <<< "$out"
          if delegate_confidence_ok "$conf" && backend="$(delegate_backend_from_model "$choice")"; then
            printf '%s\t%s\n' "$backend" "$choice"
            return 0
          fi
        fi
      fi
    fi
  fi
  delegate_fallback_model "$agent"
}

# selected_context_file（1行1パス）から CONTEXT_PROMPT と ADD_DIRS を名前渡しで埋める。
delegate_build_context() {
  local selected_file="$1"
  local -n _ctx="$2"
  local -n _dirs="$3"
  _ctx=""
  local body="" path
  [ -n "$selected_file" ] && [ -f "$selected_file" ] || return 0
  while IFS= read -r path || [ -n "$path" ]; do
    path="$(printf '%s' "$path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$path" ] || continue
    case "$path" in \#*) continue ;; esac
    if [ ! -f "$path" ] || [[ "${path,,}" != *.md && "${path,,}" != *.markdown ]]; then
      printf 'warning: selected delegate context is not a Markdown file: %s\n' "$path" >&2
      continue
    fi
    body+=$'\n- '"$path"
    _dirs+=("$(dirname "$path")")
  done < "$selected_file"
  if [ -n "$body" ]; then
    _ctx=$'\n現在のタスクに適用する追加資料は次のとおりです。これらだけを読んでルールを適用し、最終報告に「適用した追加資料」としてファイルパスを明記してください。'"$body"
  fi
}

# codex で委譲を実行する。追加 add-dir 対象は末尾の引数で渡す。
delegate_run_codex() {
  local worktree="$1" task_path="$2" model="$3" context_prompt="$4"; shift 4
  local add_dirs=("$@")
  local args=(exec -C "$worktree" --model "$model") d
  for d in "${add_dirs[@]+"${add_dirs[@]}"}"; do
    args+=(--add-dir "$d")
  done
  args+=(--dangerously-bypass-approvals-and-sandbox "${task_path} を読んで対応してください。${context_prompt}")
  if [ "${DELEGATE_SKIP_EXEC:-}" = "1" ]; then
    printf 'delegate: skipped codex exec because DELEGATE_SKIP_EXEC=1\n' >&2
    return 0
  fi
  codex "${args[@]}" < /dev/null
}

# claude で委譲を実行する（agent 指定）。cwd は変えず worktree は --add-dir で渡す。
delegate_run_claude() {
  local agent="$1" worktree="$2" task_path="$3" model="$4" context_prompt="$5"; shift 5
  local add_dirs=("$@")
  local prompt="作業対象のリポジトリは ${worktree} です。${task_path} を読んで対応してください。ファイルの作成・編集・削除は ${worktree}（および渡された inputs）内に限定すること。読み取り専用の参照やコマンド実行は、システム情報など ${worktree} 外を対象にしても禁止しない。自分の権限範囲外の作業を求められたら固定文言 DELEGATE_PERMISSION_OUT_OF_SCOPE だけを出して終了すること。${context_prompt}"
  local args=(-p "$prompt" --agent "$agent" --model "$model") d
  for d in "${add_dirs[@]+"${add_dirs[@]}"}"; do
    args+=(--add-dir "$d")
  done
  args+=(--dangerously-skip-permissions)
  if [ "${DELEGATE_SKIP_EXEC:-}" = "1" ]; then
    printf 'delegate: skipped claude exec because DELEGATE_SKIP_EXEC=1\n' >&2
    return 0
  fi
  CLAUDE_DELEGATE_SESSION=1 claude "${args[@]}" < /dev/null
}

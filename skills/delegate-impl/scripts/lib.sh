#!/usr/bin/env bash
# delegate-impl / delegate-sub / delegate-review 各スキルに同梱する実行基盤。
# 各スキルは完全に独立しており、このファイルは他スキルを参照せず自スキル配下だけで完結する。
#
# 役割:
#   - エージェント別フォールバック fallback/<agent>.tsv（backend<TAB>model）の生成
#   - 委譲ごとの Jev によるモデル判定（本文は送らず要約のみ）
#   - codex / claude（agent 指定）での委譲実行
#
# model-tiers.tsv（モデル一覧）の鮮度判定と再生成は別スキルが担う。委譲の前に、委譲先
# モデル一覧の鮮度を確認・更新するスキルを実行しておくこと。このファイルは model-tiers.tsv
# を読むだけで、不在なら fail-closed（委譲しない）。
# 接続先は api.typesafe.ai に固定する。鍵の値と指示ファイル本文はログ・出力に書かない。

DELEGATE_JEV_URL="https://api.typesafe.ai/v1/systemone"      # 固定（上書き不可）
DELEGATE_JEV_MODEL="jev-latest"
DELEGATE_JEV_TIMEOUT="${DELEGATE_JEV_TIMEOUT:-3}"
DELEGATE_JEV_CONFIDENCE_MIN="0.6"
DELEGATE_SUMMARY_MODEL="${DELEGATE_SUMMARY_MODEL:-haiku}"
DELEGATE_JEV_LAST_ERROR="" # 直近の Jev 判定失敗理由（経路トレース用）

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
  local key body resp rc out
  DELEGATE_JEV_LAST_ERROR=""
  key="${JEV_API_KEY:-}"
  if [ -z "$key" ]; then DELEGATE_JEV_LAST_ERROR="no_key"; return 1; fi
  if [ -z "$criteria_json" ] || [ "$criteria_json" = "{}" ]; then
    DELEGATE_JEV_LAST_ERROR="none"; return 1
  fi
  if ! body="$(jq -n --arg state "$summary" --arg model "$DELEGATE_JEV_MODEL" \
    --arg instr "$instructions" --argjson criteria "$criteria_json" '
    {
      state: $state,
      model: $model,
      questions: { route: { type: "choice", instructions: $instr, criteria: $criteria } }
    }')"; then
    DELEGATE_JEV_LAST_ERROR="http_error"; return 1
  fi
  resp="$(curl -fsS --max-time "$DELEGATE_JEV_TIMEOUT" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -X POST "$DELEGATE_JEV_URL" -d "$body" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 28 ]; then DELEGATE_JEV_LAST_ERROR="timeout"; else DELEGATE_JEV_LAST_ERROR="http_error"; fi
    return 1
  fi
  if ! out="$(printf '%s' "$resp" | jq -e -r '
    .answers.route
    | select(.choice != null and (.confidence | type) == "number")
    | "\(.choice)\t\(.confidence)"
  ' 2>/dev/null)"; then
    DELEGATE_JEV_LAST_ERROR="http_error"; return 1
  fi
  printf '%s\n' "$out"
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
  local agent="$1" tiers_file="$2" fallback_file="$3"; shift 3
  local backends=("$@")
  local tmp backend criteria out choice conf wrote=0
  tmp="$(mktemp)"
  for backend in "${backends[@]}"; do
    criteria="$(delegate_criteria_json "$tiers_file" "$backend")" || criteria=""
    if [ -z "$criteria" ] || [ "$criteria" = "{}" ]; then
      printf 'delegate %s fallback-gen: backend=%s source=none reason=none\n' "$agent" "$backend" >&2
      continue
    fi
    if ! out="$(delegate_jev_choice "作業全般に標準的に使うモデルを1つ選ぶ。" "$criteria" \
      "この backend の既定として最も適したモデルを選ぶ。")"; then
      printf 'delegate %s fallback-gen: backend=%s source=none reason=%s\n' \
        "$agent" "$backend" "${DELEGATE_JEV_LAST_ERROR:-none}" >&2
      continue
    fi
    IFS=$'\t' read -r choice conf <<< "$out"
    if [ -z "$choice" ]; then
      printf 'delegate %s fallback-gen: backend=%s source=none reason=http_error\n' "$agent" "$backend" >&2
      continue
    fi
    printf 'delegate %s fallback-gen: backend=%s model=%s source=jev confidence=%s\n' \
      "$agent" "$backend" "$choice" "$conf" >&2
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

# 委譲前処理: model-tiers.tsv が不在なら fail-closed（非0）。存在すれば、この agent の
# fallback が model-tiers.tsv より古い（または不在）ときだけ、フォールバック（候補 backend
# 分）を Jev で作り直す。model-tiers.tsv の鮮度確認・再生成は別スキルの担当。
delegate_ensure_tiers_and_fallback() {
  local agent="$1"; shift
  local fb_backends=("$@")
  local state_dir tiers_file fallback_file
  state_dir="$(delegate_state_dir)" || return 1
  tiers_file="$state_dir/model-tiers.tsv"
  fallback_file="$state_dir/fallback/$agent.tsv"

  if [ ! -f "$tiers_file" ]; then
    printf 'error: delegate requires model-tiers.tsv; run the model-tiers refresh skill before delegating\n' >&2
    return 1
  fi

  if [ "$tiers_file" -nt "$fallback_file" ]; then
    if ! delegate_rebuild_fallback "$agent" "$tiers_file" "$fallback_file" "${fb_backends[@]}"; then
      printf 'warning: delegate could not rebuild fallback for %s via Jev (keeping existing)\n' "$agent" >&2
    fi
  fi
  return 0
}

# 指示ファイル本文を claude -p --model haiku で「作業の種類」だけの日本語1文に要約する。
# 固有名詞・パス・URL・鍵・コードを含めない。失敗・空は非0。
delegate_summarize_task() {
  local task_path="$1" raw out
  [ -f "$task_path" ] || return 1
  [ "${DELEGATE_SKIP_LLM:-}" != "1" ] || return 1
  raw="$(delegate_summary_llm "次の委譲指示を日本語1文で要約してください。出力は『どんな種類の作業か（作業の種類と対象の種別）』だけにし、固有名詞・ファイルパス・URL・識別子・鍵・コード・引用された文字列は一切含めないこと。要約文のみを返すこと。

$(cat "$task_path")")" || return 1
  delegate_summary_ok "$raw" || return 1
  out="$(printf '%s' "$raw" | tr '\n' ' ' | sed 's/\t/ /g; s/  */ /g; s/^ //; s/ $//')"
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
  local state_dir tiers_file summary criteria out choice conf backend reason="none" fb fb_model
  state_dir="$(delegate_state_dir)" || return 1
  tiers_file="$state_dir/model-tiers.tsv"

  if [ ! -f "$tiers_file" ]; then
    reason="none"
  elif [ -z "${JEV_API_KEY:-}" ]; then
    reason="no_key"
  elif ! summary="$(delegate_summarize_task "$task_path")"; then
    reason="summary_failed"
  else
    criteria="$(delegate_criteria_json "$tiers_file" "${backends[@]}")" || criteria="{}"
    if [ -z "$criteria" ] || [ "$criteria" = "{}" ]; then
      reason="none"
    elif ! out="$(delegate_jev_choice "$summary" "$criteria" "この作業に最も適したモデルを選ぶ。")"; then
      reason="${DELEGATE_JEV_LAST_ERROR:-http_error}"
    else
      IFS=$'\t' read -r choice conf <<< "$out"
      if ! delegate_confidence_ok "$conf"; then
        reason="low_confidence"
      elif ! backend="$(delegate_backend_from_model "$choice")"; then
        reason="http_error"
      else
        printf 'delegate %s: model=%s source=jev confidence=%s\n' "$agent" "$choice" "$conf" >&2
        printf '%s\t%s\n' "$backend" "$choice"
        return 0
      fi
    fi
  fi

  fb="$(delegate_fallback_model "$agent")" || fb=""
  fb_model="$(printf '%s' "$fb" | cut -f2)"
  printf 'delegate %s: model=%s source=fallback reason=%s\n' "$agent" "${fb_model:-none}" "$reason" >&2
  [ -n "$fb" ] || return 1
  printf '%s\n' "$fb"
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

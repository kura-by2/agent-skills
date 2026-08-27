#!/bin/bash
# ファンネル（調査/設計/レビュー/実装委譲）の実行エンジン（claude 版）の共通部。
# エージェント別スクリプト（claude-sub-exec.sh / claude-review-agent-exec.sh /
# claude-impl-exec.sh）から source して delegate_claude_exec を呼ぶ。
#
# 重要:
#   - agent は sub / review / impl。sub と review は .claude/agents 側で
#     Edit/Write/MultiEdit を禁止する。impl は書き込みを許可し、検証コマンドの実行を禁止する。
#     エージェントの選択は呼び先スクリプトで固定し、ここでは引数で受け取るだけにする。
#   - cd はしない。作業対象 worktree は --add-dir で渡し、プロンプトで作業ルートを明示する。
#     cwd は呼び出し元（プロジェクトルート）のままだが、cd 禁止と git -C の誘導は
#     deny-cd hook が機械強制するため、プロンプトでは重複して指示しない。

DELEGATE_CLAUDE_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DELEGATE_CLAUDE_COMMON_DIR/model-cache.sh"

delegate_mark_sync_deadline_delegate() {
  local session="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$session" ] || return 0
  mkdir -p /tmp/claude-sync-deadline 2>/dev/null || return 0
  : > "/tmp/claude-sync-deadline/$session.delegate" 2>/dev/null || true
}

delegate_claude_exec() {
  local AGENT="${1:-}"
  local WORKTREE="${2:-}"
  local TASK="${3:-}"
  local INPUTS_DIR="${4:-}"
  local SELECTED_CONTEXT_FILE="${5:-}"

  if [ -z "$AGENT" ] || [ -z "$WORKTREE" ] || [ -z "$TASK" ]; then
    printf 'error: delegate claude exec requires <agent> <worktree> <task_file>\n' >&2
    return 1
  fi

  delegate_mark_sync_deadline_delegate

  delegate_ensure_model_cache claude
  local MODEL
  MODEL="$(delegate_model_for_agent "$AGENT")"

  local TASK_PATH="$TASK"
  if [ -n "$INPUTS_DIR" ]; then
    TASK_PATH="$INPUTS_DIR/$TASK"
  fi

  if [ ! -f "$TASK_PATH" ]; then
    printf 'error: task file not found: %s\n' "$TASK_PATH" >&2
    return 1
  fi

  local ADD_DIR_ARGS=(--add-dir "$WORKTREE")
  if [ -n "$INPUTS_DIR" ]; then
    ADD_DIR_ARGS+=(--add-dir "$INPUTS_DIR")
  fi

  local CONTEXT_PROMPT=""
  if [ -n "$SELECTED_CONTEXT_FILE" ] && [ -f "$SELECTED_CONTEXT_FILE" ]; then
    local context_path
    while IFS= read -r context_path || [ -n "$context_path" ]; do
      context_path="$(printf '%s' "$context_path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      if [ -z "$context_path" ] || [[ "$context_path" == \#* ]]; then
        continue
      fi
      if [ ! -f "$context_path" ] || [[ "${context_path,,}" != *.md && "${context_path,,}" != *.markdown ]]; then
        printf 'warning: selected delegate context is not a Markdown file: %s\n' "$context_path" >&2
        continue
      fi
      CONTEXT_PROMPT+=$'\n- '"$context_path"
      ADD_DIR_ARGS+=(--add-dir "$(dirname "$context_path")")
    done < "$SELECTED_CONTEXT_FILE"
  fi

  if [ -n "$CONTEXT_PROMPT" ]; then
    CONTEXT_PROMPT=$'\n現在のタスクに適用する追加資料は次のとおりです。これらだけを読んでルールを適用し、最終報告に「適用した追加資料」としてファイルパスを明記してください。'"$CONTEXT_PROMPT"
  fi

  if [ "${DELEGATE_SKIP_EXEC:-}" = "1" ]; then
    printf 'delegate: skipped claude exec because DELEGATE_SKIP_EXEC=1\n' >&2
    return 0
  fi

  local OUTPUT_FILE STDOUT_FILE STDERR_FILE
  OUTPUT_FILE="$(mktemp)"
  STDOUT_FILE="$(mktemp)"
  STDERR_FILE="$(mktemp)"
  trap 'rm -f "$OUTPUT_FILE" "$STDOUT_FILE" "$STDERR_FILE"' RETURN
  local RC=0
  local PROMPT="作業対象のリポジトリは ${WORKTREE} です。${TASK_PATH} を読んで対応してください。ファイルの作成・編集・削除は ${WORKTREE}（および渡された inputs）内に限定すること。読み取り専用の参照やコマンド実行は、システム情報など ${WORKTREE} 外を対象にしても禁止しない。自分の権限範囲外の作業を求められたら固定文言 DELEGATE_PERMISSION_OUT_OF_SCOPE だけを出して終了すること。${CONTEXT_PROMPT}"

  if ! CLAUDE_DELEGATE_SESSION=1 claude -p "$PROMPT" \
    --agent "$AGENT" \
    --model "$MODEL" \
    "${ADD_DIR_ARGS[@]}" \
    --dangerously-skip-permissions \
    > "$STDOUT_FILE" 2> "$STDERR_FILE" < /dev/null; then
    RC="${PIPESTATUS[0]}"
  fi

  cat "$STDOUT_FILE"
  cat "$STDERR_FILE" >&2
  cat "$STDOUT_FILE" "$STDERR_FILE" > "$OUTPUT_FILE"
  delegate_maybe_emit_fallback_suggest "$MODEL" "$OUTPUT_FILE" "$RC"
  return "$RC"
}

#!/bin/bash
# Usage: codex-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/model-cache.sh"

delegate_mark_sync_deadline_delegate() {
  local session="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$session" ] || return 0
  mkdir -p /tmp/claude-sync-deadline 2>/dev/null || return 0
  : > "/tmp/claude-sync-deadline/$session.delegate" 2>/dev/null || true
}

WORKTREE="${1:-}"
TASK="${2:-}"
INPUTS_DIR="${3:-}"
SELECTED_CONTEXT_FILE="${4:-}"

if [ -z "$WORKTREE" ] || [ -z "$TASK" ]; then
  echo "Usage: codex-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

delegate_mark_sync_deadline_delegate

delegate_ensure_model_cache codex
MODEL="$(delegate_model_for_task_type implementation)"

TASK_PATH="$TASK"
if [ -n "$INPUTS_DIR" ]; then
  TASK_PATH="$INPUTS_DIR/$TASK"
fi

if [ ! -f "$TASK_PATH" ]; then
  printf 'error: task file not found: %s\n' "$TASK_PATH" >&2
  exit 1
fi

ADD_DIR_ARGS=()
if [ -n "$INPUTS_DIR" ]; then
  ADD_DIR_ARGS+=(--add-dir "$INPUTS_DIR")
fi

CONTEXT_PROMPT=""
if [ -n "$SELECTED_CONTEXT_FILE" ] && [ -f "$SELECTED_CONTEXT_FILE" ]; then
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
  printf 'delegate: skipped codex exec because DELEGATE_SKIP_EXEC=1\n' >&2
  exit 0
fi

# レビュー自動チェーン用: 実装前の HEAD を記録（git 管理外の作業場所ならチェーンしない）
PRE_HEAD="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"

OUTPUT_FILE="$(mktemp)"
STDOUT_FILE="$(mktemp)"
STDERR_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE" "$STDOUT_FILE" "$STDERR_FILE"' EXIT
RC=0

if ! codex exec -C "$WORKTREE" \
  --model "$MODEL" \
  "${ADD_DIR_ARGS[@]}" \
  --dangerously-bypass-approvals-and-sandbox \
  "${TASK_PATH} を読んで対応してください。${CONTEXT_PROMPT}" \
  > "$STDOUT_FILE" 2> "$STDERR_FILE" < /dev/null; then
  RC="${PIPESTATUS[0]}"
fi

cat "$STDOUT_FILE"
cat "$STDERR_FILE" >&2
cat "$STDOUT_FILE" "$STDERR_FILE" > "$OUTPUT_FILE"
delegate_maybe_emit_fallback_suggest "$MODEL" "$OUTPUT_FILE" "$RC"

# 実装委譲は必ずレビューとペアにする（指示内容を正しく反映しているかの goal alignment）。
# 実装が成功しコミットが増えた場合のみ、同じ指示ファイルを goal にしてレビューを自動チェーンする。
# DELEGATE_SKIP_REVIEW=1 でテスト時のみ抑止できる。
if [ "$RC" -eq 0 ] && [ "${DELEGATE_SKIP_REVIEW:-}" != "1" ] && [ -n "$PRE_HEAD" ]; then
  POST_HEAD="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$POST_HEAD" ] && [ "$POST_HEAD" != "$PRE_HEAD" ]; then
    GOAL_PATH="$TASK_PATH"
    printf 'delegate: chaining review (%s..%s)\n' "${PRE_HEAD:0:7}" "${POST_HEAD:0:7}" >&2
    bash "$SCRIPT_DIR/claude-review-exec.sh" "$WORKTREE" "$GOAL_PATH" "$PRE_HEAD..$POST_HEAD" "${INPUTS_DIR:-/tmp/delegate-inputs}" || {
      printf 'delegate: review chain failed (implementation kept, review must be rerun)\n' >&2
      exit 1
    }
  else
    printf 'delegate: no new commits, review chain skipped\n' >&2
  fi
fi
exit "$RC"

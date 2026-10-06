#!/usr/bin/env bash
# Usage: claude-review-agent-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
# ゴールアライメントレビュー委譲用（review エージェント、書き込み禁止・claude のみ）。
# 指示ファイルは claude-review-exec.sh / claude-review-files-exec.sh が生成する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORKTREE="${1:-}"
TASK="${2:-}"
INPUTS_DIR="${3:-}"
SELECTED_CONTEXT_FILE="${4:-}"

if [ -z "$WORKTREE" ] || [ -z "$TASK" ]; then
  echo "Usage: claude-review-agent-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

delegate_mark_sync_deadline_delegate

TASK_PATH="$TASK"
[ -n "$INPUTS_DIR" ] && TASK_PATH="$INPUTS_DIR/$TASK"
if [ ! -f "$TASK_PATH" ]; then
  printf 'error: task file not found: %s\n' "$TASK_PATH" >&2
  exit 1
fi

# 委譲前: model-tiers.tsv（別スキルが鮮度管理）が不在なら fail-closed。存在すれば、review
# フォールバック（claude の1行）が model-tiers より古い/不在のときだけ作り直す。
if ! delegate_ensure_tiers_and_fallback review claude; then
  printf 'error: delegate review cannot run because no model tier is available (fail-closed)\n' >&2
  exit 1
fi

# 主選定: Jev（候補は claude のみ）→ だめなら fallback/review.tsv。
RESOLVED="$(delegate_resolve_model review "$TASK_PATH" claude)" || true
if [ -z "$RESOLVED" ]; then
  printf 'error: delegate review cannot resolve a model and no fallback exists (fail-closed)\n' >&2
  exit 1
fi
IFS=$'\t' read -r BACKEND MODEL <<< "$RESOLVED"

CONTEXT_PROMPT=""
CONTEXT_DIRS=()
delegate_build_context "$SELECTED_CONTEXT_FILE" CONTEXT_PROMPT CONTEXT_DIRS

DIRS=()
[ -n "$INPUTS_DIR" ] && DIRS+=("$INPUTS_DIR")
DIRS+=("${CONTEXT_DIRS[@]+"${CONTEXT_DIRS[@]}"}")

printf 'delegate review: model=%s\n' "$MODEL" >&2
delegate_run_claude review "$WORKTREE" "$TASK_PATH" "$MODEL" "$CONTEXT_PROMPT" \
  "$WORKTREE" "${DIRS[@]+"${DIRS[@]}"}"

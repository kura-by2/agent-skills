#!/usr/bin/env bash
# Usage: claude-sub-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
# 調査/現状把握/設計/トレードオフ比較の委譲用（sub エージェント、書き込み禁止・claude のみ）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORKTREE="${1:-}"
TASK="${2:-}"
INPUTS_DIR="${3:-}"
SELECTED_CONTEXT_FILE="${4:-}"

if [ -z "$WORKTREE" ] || [ -z "$TASK" ]; then
  echo "Usage: claude-sub-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

delegate_mark_sync_deadline_delegate

TASK_PATH="$TASK"
[ -n "$INPUTS_DIR" ] && TASK_PATH="$INPUTS_DIR/$TASK"
if [ ! -f "$TASK_PATH" ]; then
  printf 'error: task file not found: %s\n' "$TASK_PATH" >&2
  exit 1
fi

# 起動時: model-tiers が1日以上前/不在なら再生成し、sub フォールバック（claude の1行）も作る。
if ! delegate_refresh_tiers_and_fallback sub claude; then
  printf 'error: delegate sub cannot run because no model tier is available (fail-closed)\n' >&2
  exit 1
fi

# 主選定: Jev（候補は claude のみ）→ だめなら fallback/sub.tsv。
RESOLVED="$(delegate_resolve_model sub "$TASK_PATH" claude)" || true
if [ -z "$RESOLVED" ]; then
  printf 'error: delegate sub cannot resolve a model and no fallback exists (fail-closed)\n' >&2
  exit 1
fi
IFS=$'\t' read -r BACKEND MODEL <<< "$RESOLVED"

CONTEXT_PROMPT=""
CONTEXT_DIRS=()
delegate_build_context "$SELECTED_CONTEXT_FILE" CONTEXT_PROMPT CONTEXT_DIRS

DIRS=()
[ -n "$INPUTS_DIR" ] && DIRS+=("$INPUTS_DIR")
DIRS+=("${CONTEXT_DIRS[@]+"${CONTEXT_DIRS[@]}"}")

printf 'delegate sub: model=%s\n' "$MODEL" >&2
delegate_run_claude sub "$WORKTREE" "$TASK_PATH" "$MODEL" "$CONTEXT_PROMPT" \
  "$WORKTREE" "${DIRS[@]+"${DIRS[@]}"}"

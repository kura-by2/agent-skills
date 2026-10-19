#!/usr/bin/env bash
# Usage: codex-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/delegate-common.sh"

WORKTREE="${1:-}"
TASK="${2:-}"
INPUTS_DIR="${3:-}"
SELECTED_CONTEXT_FILE="${4:-}"

if [ -z "$WORKTREE" ] || [ -z "$TASK" ]; then
  echo "Usage: codex-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

STDOUT_FILE="$(mktemp)"
trap 'rm -f "$STDOUT_FILE"' EXIT
RC=0
delegate_exec_for_task_type implementation impl "$WORKTREE" "$TASK" "$INPUTS_DIR" "$SELECTED_CONTEXT_FILE" > "$STDOUT_FILE" || RC=$?
cat "$STDOUT_FILE"

REVIEW_FILES="$(awk -F '\t' '$1 == "DELEGATE_CHANGED_FILE" && $2 ~ /^\// && NF == 2 { print $2 }' "$STDOUT_FILE" | sort -u)"
if [ -n "$REVIEW_FILES" ]; then
  while IFS= read -r review_file; do
    printf 'DELEGATE_REVIEW_FILE\t%s\n' "$review_file"
  done <<< "$REVIEW_FILES"
else
  printf 'DELEGATE_REVIEW_UNRESOLVED\t%s\tno_declared_files\n' "$WORKTREE"
fi
exit "$RC"

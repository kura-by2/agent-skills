#!/usr/bin/env bash
# Usage: codex-impl-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/delegate-common.sh"

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "Usage: codex-impl-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

WORKTREE="$1"
STDOUT_FILE="$(mktemp)"
trap 'rm -f "$STDOUT_FILE"' EXIT
RC=0
delegate_exec_for_backend implementation codex impl "$@" > "$STDOUT_FILE" || RC=$?
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

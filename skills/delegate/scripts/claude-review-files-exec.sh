#!/bin/bash
# Usage: claude-review-files-exec.sh <worktree> <goal_file> <files> [inputs_dir]
# ファイルパス指定レビュー委譲用の薄いラッパ。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKTREE="${1:-}"
GOAL_FILE="${2:-}"
FILES="${3:-}"
INPUTS_DIR="${4:-/tmp/delegate-inputs}"

if [ -z "$WORKTREE" ] || [ -z "$GOAL_FILE" ] || [ -z "$FILES" ]; then
  echo "Usage: claude-review-files-exec.sh <worktree> <goal_file> <files> [inputs_dir]"
  exit 1
fi

if [ ! -d "$WORKTREE" ]; then
  printf 'error: worktree is not a directory: %s\n' "$WORKTREE" >&2
  exit 1
fi

if [ ! -f "$GOAL_FILE" ]; then
  printf 'error: goal file is not readable: %s\n' "$GOAL_FILE" >&2
  exit 1
fi

if [ -z "${FILES//[[:space:]]/}" ]; then
  printf 'error: files is empty\n' >&2
  exit 1
fi

FILE_LINES=""
for FILE in $FILES; do
  if [[ "$FILE" = /* ]]; then
    FILE_PATH="$FILE"
  else
    FILE_PATH="$WORKTREE/$FILE"
  fi

  if [ ! -f "$FILE_PATH" ]; then
    printf 'error: file not found: %s\n' "$FILE" >&2
    exit 1
  fi

  FILE_LINES="${FILE_LINES}${FILE_PATH}"$'\n'
done

mkdir -p "$INPUTS_DIR"

TASK_FILE="$(mktemp "$INPUTS_DIR/review-XXXXXX.md")"
TASK_NAME="$(basename "$TASK_FILE")"

cat > "$TASK_FILE" <<EOF
# Review指示ファイル

## goal
goal: $GOAL_FILE

## files
files:
$FILE_LINES
## note
対象は差分ではなく成果物のファイル全文です。
git 管理外・新規作成のファイルを含む前提のため、差分は取らず、上記ファイルの全文を読んでレビューしてください。
EOF

exec bash "$SCRIPT_DIR/claude-review-agent-exec.sh" "$WORKTREE" "$TASK_NAME" "$INPUTS_DIR"

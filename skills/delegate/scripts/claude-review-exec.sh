#!/bin/bash
# Usage: claude-review-exec.sh <worktree> <goal_file> [diff_range] [inputs_dir]
# ゴールアライメントレビュー委譲用の薄いラッパ。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKTREE="${1:-}"
GOAL_FILE="${2:-}"
DIFF_RANGE="${3:-HEAD}"
INPUTS_DIR="${4:-/tmp/delegate-inputs}"

if [ -z "$WORKTREE" ] || [ -z "$GOAL_FILE" ]; then
  echo "Usage: claude-review-exec.sh <worktree> <goal_file> [diff_range] [inputs_dir]"
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

mkdir -p "$INPUTS_DIR"

TASK_FILE="$(mktemp "$INPUTS_DIR/review-XXXXXX.md")"
TASK_NAME="$(basename "$TASK_FILE")"

cat > "$TASK_FILE" <<EOF
# Review指示ファイル

## goal
goal: $GOAL_FILE

## target
target: $WORKTREE $DIFF_RANGE
EOF

exec bash "$SCRIPT_DIR/claude-review-agent-exec.sh" "$WORKTREE" "$TASK_NAME" "$INPUTS_DIR"

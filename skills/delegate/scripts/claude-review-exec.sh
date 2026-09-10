#!/bin/bash
# Usage: claude-review-exec.sh <worktree> <goal1> <diff1> [<goal2> <diff2> ...] [--inputs-dir <dir>]
# ゴールアライメントレビュー委譲用の薄いラッパ。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKTREE="${1:-}"
INPUTS_DIR="/tmp/delegate-inputs"

if [ -z "$WORKTREE" ]; then
  echo "Usage: claude-review-exec.sh <worktree> <goal1> <diff1> [<goal2> <diff2> ...] [--inputs-dir <dir>]"
  exit 1
fi

shift

if [ "$#" -ge 2 ] && [ "${!#}" != "--inputs-dir" ]; then
  PREV_INDEX=$(($# - 1))
  if [ "${!PREV_INDEX}" = "--inputs-dir" ]; then
    INPUTS_DIR="${!#}"
    set -- "${@:1:$(($# - 2))}"
  fi
fi

# 従来の単一ペア + inputs_dir の呼び出しは維持する。
if [ "$#" -eq 3 ] && [ ! -f "$3" ]; then
  INPUTS_DIR="$3"
  set -- "$1" "$2"
fi

if [ "$#" -eq 1 ]; then
  set -- "$1" HEAD
elif [ "$#" -eq 0 ] || [ $(($# % 2)) -ne 0 ]; then
  printf 'error: goal and diff range must be specified in pairs\n' >&2
  exit 1
fi

if [ ! -d "$WORKTREE" ]; then
  printf 'error: worktree is not a directory: %s\n' "$WORKTREE" >&2
  exit 1
fi

for ((INDEX = 1; INDEX <= $#; INDEX += 2)); do
  GOAL_FILE="${!INDEX}"
  if [ ! -f "$GOAL_FILE" ]; then
    printf 'error: goal file is not readable: %s\n' "$GOAL_FILE" >&2
    exit 1
  fi
done

mkdir -p "$INPUTS_DIR"

TASK_FILE="$(mktemp "$INPUTS_DIR/review-XXXXXX.md")"
TASK_NAME="$(basename "$TASK_FILE")"

cat > "$TASK_FILE" <<'EOF'
# Review指示ファイル

## reviews
EOF

for ((INDEX = 1; INDEX <= $#; INDEX += 2)); do
  DIFF_INDEX=$((INDEX + 1))
  printf 'goal: %s\ntarget: %s %s\n' "${!INDEX}" "$WORKTREE" "${!DIFF_INDEX}" >> "$TASK_FILE"
done

exec bash "$SCRIPT_DIR/claude-review-agent-exec.sh" "$WORKTREE" "$TASK_NAME" "$INPUTS_DIR"

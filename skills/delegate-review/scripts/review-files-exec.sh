#!/usr/bin/env bash
# Usage: review-files-exec.sh <worktree> <goal_file> <files> [inputs_dir] [--range <diff_range>]
# ゴールアライメントレビュー委譲用の薄いラッパ（ファイルパス指定）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USAGE='Usage: review-files-exec.sh <worktree> <goal_file> <files> [inputs_dir] [--range <diff_range>]'

DIFF_RANGE=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --range)
      if [ -z "${2:-}" ]; then
        printf 'error: --range requires a diff range\n' >&2
        exit 1
      fi
      DIFF_RANGE="$2"
      shift 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- ${POSITIONAL+"${POSITIONAL[@]}"}

WORKTREE="${1:-}"
GOAL_FILE="${2:-}"
FILES="${3:-}"
INPUTS_DIR="${4:-/tmp/delegate-inputs}"

if [ -z "$WORKTREE" ] || [ -z "$GOAL_FILE" ] || [ -z "$FILES" ]; then
  echo "$USAGE"
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
EOF

if [ -n "$DIFF_RANGE" ]; then
  cat >> "$TASK_FILE" <<EOF
## range
range: $DIFF_RANGE

## note
git 管理下のファイルは、レビュー対象を上記 range の差分に限ります。\`git -C $WORKTREE diff $DIFF_RANGE -- <file>\` で変更内容を確認してください。
ファイル全文は差分を解釈するための文脈としてのみ読み、差分に含まれない既存コードへの指摘はしないでください。
git 管理外・新規作成のファイルは差分に出ないため、全文をレビュー対象とします。
EOF
else
  cat >> "$TASK_FILE" <<EOF
## note
対象は差分ではなく成果物のファイル全文です。
git 管理外・新規作成のファイルを含む前提のため、差分は取らず、上記ファイルの全文を読んでレビューしてください。
EOF
fi

exec bash "$SCRIPT_DIR/review-agent-exec.sh" "$WORKTREE" "$TASK_NAME" "$INPUTS_DIR"

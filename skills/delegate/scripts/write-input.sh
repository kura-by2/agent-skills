#!/usr/bin/env bash
# Usage: write-input.sh <task_name> [inputs_dir]   (指示本文は stdin から渡す)
# delegate の指示ファイルを <inputs_dir>/<task_name>.md に作成するだけの薄いラッパ。
# enforce-sync-deadline フックで明示許可される「委譲の下準備」専用コマンド。
# 汎用 Write/cat を締切後に開けずに、delegate 入力生成だけを穴にするために存在する。
set -euo pipefail

TASK="${1:-}"
INPUTS_DIR="${2:-/tmp/delegate-inputs}"
if [ -z "$TASK" ]; then
  echo "Usage: write-input.sh <task_name> [inputs_dir]  (本文は stdin)" >&2
  exit 1
fi

# ディレクトリトラバーサル防止: task_name は単純なファイル名のみ許可
case "$TASK" in
  */*|..*) echo "task_name にパス区切りは使えない: $TASK" >&2; exit 1;;
esac

mkdir -p "$INPUTS_DIR"
OUT="$INPUTS_DIR/${TASK%.md}.md"

BODY=$(cat)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE="$SCRIPT_DIR/../inputs/_template.md"
if [ ! -r "$TEMPLATE" ]; then
  printf 'error: template is not readable: %s\n' "$TEMPLATE" >&2
  exit 1
fi

MISSING_SECTIONS=()
while IFS= read -r heading; do
  if ! printf '%s\n' "$BODY" | grep -Fxq "$heading"; then
    MISSING_SECTIONS+=("$heading")
  fi
done < <(grep '^## ' "$TEMPLATE")

if [ "${#MISSING_SECTIONS[@]}" -gt 0 ]; then
  echo "error: 指示ファイルに必須セクションがない: $TASK" >&2
  printf '  - %s\n' "${MISSING_SECTIONS[@]}" >&2
  exit 1
fi

printf '%s\n' "$BODY" > "$OUT"
echo "wrote: $OUT"

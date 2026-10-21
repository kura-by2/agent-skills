#!/usr/bin/env bash
# Usage: write-input.sh <task_name> [inputs_dir]   (goal 本文は stdin から渡す)
# review の goal ファイルを <inputs_dir>/<task_name>.md に作成するだけの薄いラッパ。
# enforce-sync-deadline フックで明示許可される「委譲の下準備」専用コマンド。
# 汎用 Write/cat を締切後に開けずに、delegate 入力生成だけを穴にするために存在する。
# review の goal は自由記述のため、指示テンプレの必須セクション検査は課さない。
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

# 既存の同名 goal ファイルは書き込み前にバックアップ名へ退避する。
# 古い内容が残ると、後続の実行スクリプトがそれを読んで委譲してしまうため。
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
  mv -- "$OUT" "$OUT.bak-$(date +%Y%m%d-%H%M%S%3N)" >&2
fi

printf '%s\n' "$BODY" > "$OUT"
echo "wrote: $OUT"

#!/usr/bin/env bash
# Usage: rebuild-index.sh
# {topic}.md 群から index.md を機械的に再生成する。
# - updated はフロントマターの updated:
# - summary は goal-stack の最初の未完了項目、無ければ最後の完了項目のゴール文
# - フロントマターに merged_into: があるトピック（統合済み）は除外する
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/context-dir.sh"
if [ ! -d "$DIR" ]; then
  echo "コンテキストディレクトリがありません: $DIR" >&2
  exit 1
fi

OUT="$DIR/index.md"
TMP=$(mktemp)

{
  echo "| topic | updated | last_loaded | summary |"
  echo "|-------|---------|-------------|---------|"
  for f in "$DIR"/*.md; do
    base=$(basename "$f")
    [ "$base" = "index.md" ] && continue
    grep -q '^merged_into:' "$f" && continue
    topic="${base%.md}"
    updated=$(awk -F': *' '/^updated:/{print $2; exit}' "$f")
    last_loaded=$(awk -F': *' '/^last_loaded:/{print $2; exit}' "$f")
    summary=$(awk '
      /^## goal-stack[[:space:]]*$/ { section = 1; next }
      section && /^## / { exit }
      section && /^- \[ \] / {
        sub(/^- \[ \] /, "")
        sub(/[[:space:]]*<!--[[:space:]]*pushed:.*-->[[:space:]]*$/, "")
        found = 1
        print
        exit
      }
      section && /^- \[x\] / {
        sub(/^- \[x\] /, "")
        sub(/[[:space:]]*<!--[[:space:]]*pushed:.*-->[[:space:]]*$/, "")
        completed = $0
      }
      END { if (!found && completed != "") print completed }
    ' "$f")
    echo "| $topic | ${updated:--} | ${last_loaded:--} | ${summary:--} |"
  done
} > "$TMP"

mv "$TMP" "$OUT"
TOPICS=$(( $(wc -l < "$OUT") - 2 ))
echo "index.md を再生成しました（${TOPICS}トピック）"

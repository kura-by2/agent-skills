#!/usr/bin/env bash
# Usage: handoff-context.sh <parent-topic> <child-topic>
# 親トピックの決定事項と goal-stack の未完了項目をスナップショットし、次フェーズ用の子トピックを作る。
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/context-dir.sh"
parent="${1:?Usage: handoff-context.sh <parent-topic> <child-topic>}"
child="${2:?Usage: handoff-context.sh <parent-topic> <child-topic>}"
parent_file="$DIR/$parent.md"
child_file="$DIR/$child.md"

[ -f "$parent_file" ] || { echo "親コンテキストがありません: $parent" >&2; exit 1; }
[ ! -e "$child_file" ] || { echo "コンテキスト $child は既に存在します" >&2; exit 1; }

mkdir -p "$DIR"
today=$(date +%F)
tmp=$(mktemp)

awk '
  /^## goal-stack[[:space:]]*$/ { section = "goals"; next }
  /^## 決定事項[[:space:]]*$/ { section = "decisions"; next }
  /^## / { section = ""; next }
  section == "goals" && /^- \[ \]/ { goals = goals $0 "\n" }
  section == "decisions" { decisions = decisions $0 "\n" }
  END {
    printf("## goal-stack\n")
    if (goals ~ /[^[:space:]]/) {
      printf("%s", goals)
    }
    printf("\n## review-stack\n\n")
    printf("## 決定事項\n")
    if (decisions ~ /[^[:space:]]/) {
      printf("%s", decisions)
    }
  }
' parent="$parent" "$parent_file" > "$tmp"

{
  printf -- '---\ntopic: %s\nupdated: %s\nlast_loaded: %s\ndepends_on:\n  - %s\n---\n\n' "$child" "$today" "$today" "$parent"
  cat "$tmp"
} > "$child_file"
rm -f "$tmp"

bash "$(dirname "$0")/rebuild-index.sh"
echo "引き継ぎ: $parent_file → $child_file"

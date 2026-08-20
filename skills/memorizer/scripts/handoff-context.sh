#!/bin/bash
# Usage: handoff-context.sh <parent-topic> <child-topic>
# 親トピックの決定事項と次のアクションをスナップショットし、次フェーズ用の子トピックを作る。
set -euo pipefail

DIR="./memory/contexts"
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
  /^## 決定事項[[:space:]]*$/ { section = "decisions"; next }
  /^## 次のアクション[[:space:]]*$/ { section = "actions"; next }
  /^## / { section = ""; next }
  section == "decisions" { decisions = decisions $0 "\n" }
  section == "actions" { actions = actions $0 "\n" }
  END {
    printf("## 現在の状態\n")
    printf("親トピック `%s` から次フェーズへ引き継いだコンテキスト。\n\n\n", parent)
    printf("## 決定事項\n")
    if (decisions ~ /[^[:space:]]/) {
      printf("%s", decisions)
    }
    printf("\n## 次のアクション\n")
    if (actions ~ /[^[:space:]]/) {
      printf("%s", actions)
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

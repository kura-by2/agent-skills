#!/bin/bash
# Usage: new-context.sh <topic>
set -euo pipefail

DIR="./memory/contexts"
topic="${1:?Usage: new-context.sh <topic>}"
f="$DIR/$topic.md"

if [ -e "$f" ]; then
  echo "コンテキスト $topic は既に存在します" >&2
  exit 1
fi

mkdir -p "$DIR"
today=$(date +%F)
cat > "$f" <<EOF
---
topic: $topic
updated: $today
last_loaded: $today
---

## 現在の状態


## 決定事項


## 次のアクション
EOF

bash "$(dirname "$0")/rebuild-index.sh"
echo "作成: $f"

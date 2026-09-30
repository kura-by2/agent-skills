#!/usr/bin/env bash
# Usage: mark-merged.sh <merged_into> <old_topic...>
# 旧トピックのフロントマターに merged_into を付与し index を再生成する。
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/context-dir.sh"
merged="${1:?Usage: mark-merged.sh <merged_into> <old_topic...>}"
shift

for old in "$@"; do
  f="$DIR/$old.md"
  [ -f "$f" ] || { echo "not found: $old" >&2; continue; }
  bash "$(dirname "$0")/fm-set.sh" "$f" merged_into "$merged"
done

bash "$(dirname "$0")/rebuild-index.sh"
echo "merged_into=$merged を設定: $*"

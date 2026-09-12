#!/bin/bash
# Usage: append-log.sh <topic> <text_file>
# text_file の内容を $AGENT_PROJECT_DIR/memory/contexts/<topic>/context-log.md に追記する。
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/context-dir.sh"
topic="${1:?Usage: append-log.sh <topic> <text_file>}"
text="${2:?Usage: append-log.sh <topic> <text_file>}"
[ -f "$text" ] || { echo "追記ファイルがありません: $text" >&2; exit 1; }

logdir="$DIR/$topic"
mkdir -p "$logdir"
log="$logdir/context-log.md"
{ [ -s "$log" ] && echo; cat "$text"; } >> "$log"
echo "追記: $log"

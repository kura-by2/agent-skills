#!/usr/bin/env bash
# PostToolUse(Bash): 叩いたコマンドを日付別ログに記録する（CLI/手順候補検出の原データ）。
# 出力先は $CLAUDE_PROJECT_DIR/logs/commands/<date>.log（gitignore対象）。1行 = command。
dir="${CLAUDE_PROJECT_DIR:?}/logs/commands"
mkdir -p "$dir"
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' | tr '\n' ' ')
[ -n "$cmd" ] && printf '%s\n' "$cmd" >> "$dir/$(date +%F).log"

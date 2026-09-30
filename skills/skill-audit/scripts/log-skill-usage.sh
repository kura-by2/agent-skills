#!/usr/bin/env bash
# PostToolUse(Skill): スキル使用を記録する（未使用スキルの退避判断の原データ）
dir="${CLAUDE_PROJECT_DIR:?}/logs"
mkdir -p "$dir"
skill=$(jq -r '.tool_input.skill // empty')
if [ -n "$skill" ]; then
  printf '%s\t%s\n' "$(date +%F)" "$skill" >> "$dir/skill-usage.log"
fi

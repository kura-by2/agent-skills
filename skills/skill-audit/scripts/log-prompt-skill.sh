#!/usr/bin/env bash
# UserPromptSubmit: ユーザーがスラッシュコマンドで明示起動したスキルを skill-usage.log に記録する。
# agent frontmatter では UserPromptSubmit が効かないため settings.json に登録し、
# main 以外は agent_type で除外して収集対象を main エージェントに揃える。
# PostToolUse(Skill) はエージェント自発起動を拾い、こちらはユーザー明示起動を拾う（両者は排他）。
dir="${CLAUDE_PROJECT_DIR:?}/logs"
mkdir -p "$dir"
input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.agent_type // empty')" = "main" ] || exit 0
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty')
skill=$(printf '%s' "$prompt" | grep -oE '^/[a-z0-9_-]+' | head -1 | sed 's|^/||')
[ -z "$skill" ] && exit 0
if [ -d "$HOME/.claude/skills/$skill" ] || [ -d "${CLAUDE_PROJECT_DIR:-/mnt/playground/agent}/.claude/skills/$skill" ]; then
  printf '%s\t%s\n' "$(date +%F)" "$skill" >> "$dir/skill-usage.log"
fi

#!/usr/bin/env bash
# プロジェクトルートを解決する共通スクリプト。リポジトリ直下に置き、どのスキルからも呼ぶ。
#
# 解決順: AGENT_PROJECT_DIR → CLAUDE_PROJECT_DIR → カレントの git リポジトリルート。
#
# 出力・終了コード:
#   成功時: stdout にプロジェクトルートの絶対パス、終了コード 0。
#   失敗時: stderr に失敗理由1行、終了コード 非0。
set -u

project_dir="${AGENT_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$project_dir" ]; then
  project_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || true
fi
if [ -z "$project_dir" ]; then
  printf 'error: unable to resolve project root from AGENT_PROJECT_DIR, CLAUDE_PROJECT_DIR, or the current git repository\n' >&2
  exit 1
fi
printf '%s\n' "$project_dir"

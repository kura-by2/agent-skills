#!/bin/bash
# Usage: claude-impl-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
# 実装委譲用（impl エージェント、書き込み・コミット許可／検証コマンド禁止）。
# codex が使えない場合のフォールバックとして実装を回す。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/claude-common.sh"

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "Usage: claude-impl-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

delegate_claude_exec impl "$@"

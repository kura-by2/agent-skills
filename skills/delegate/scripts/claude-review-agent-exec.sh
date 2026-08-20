#!/bin/bash
# Usage: claude-review-agent-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
# レビュー委譲用（review エージェント、書き込み禁止）。
# 指示ファイルは claude-review-exec.sh / claude-review-files-exec.sh が生成する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/claude-common.sh"

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "Usage: claude-review-agent-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

delegate_claude_exec review "$@"

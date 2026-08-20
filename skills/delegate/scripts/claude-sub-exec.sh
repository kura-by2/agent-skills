#!/bin/bash
# Usage: claude-sub-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
# 調査/現状把握/設計/トレードオフ比較の委譲用（sub エージェント、書き込み禁止）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/claude-common.sh"

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "Usage: claude-sub-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

delegate_claude_exec sub "$@"

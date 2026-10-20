#!/usr/bin/env bash
# Usage: codex-sub-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/delegate-common.sh"

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "Usage: codex-sub-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

delegate_exec_for_backend other codex sub "$@"

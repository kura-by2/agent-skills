#!/usr/bin/env bash
# Usage: codex-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/codex-impl-exec.sh" "$@"

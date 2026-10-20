#!/usr/bin/env bash
# Usage: claude-review-files-exec.sh <worktree> <goal_file> <files> [inputs_dir] [--range <diff_range>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/review-common.sh"

delegate_review_files_exec "$SCRIPT_DIR/claude-review-agent-exec.sh" "$@" || {
  RC=$?
  [ "$RC" -ne 2 ] || echo "Usage: claude-review-files-exec.sh <worktree> <goal_file> <files> [inputs_dir] [--range <diff_range>]"
  exit "$RC"
}

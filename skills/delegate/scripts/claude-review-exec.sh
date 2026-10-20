#!/usr/bin/env bash
# Usage: claude-review-exec.sh <worktree> <goal1> <diff1> [<goal2> <diff2> ...] [--inputs-dir <dir>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/review-common.sh"

delegate_review_diff_exec "$SCRIPT_DIR/claude-review-agent-exec.sh" "$@" || {
  RC=$?
  [ "$RC" -ne 2 ] || echo "Usage: claude-review-exec.sh <worktree> <goal1> <diff1> [<goal2> <diff2> ...] [--inputs-dir <dir>]"
  exit "$RC"
}

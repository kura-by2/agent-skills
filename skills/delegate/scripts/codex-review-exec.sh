#!/usr/bin/env bash
# Usage: codex-review-exec.sh <worktree> <goal1> <diff1> [...] [--inputs-dir <dir>]
#        codex-review-exec.sh --files <worktree> <goal_file> <files> [inputs_dir] [--range <diff_range>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/review-common.sh"

RUNNER="$SCRIPT_DIR/codex-review-agent-exec.sh"
if [ "${1:-}" = "--files" ]; then
  shift
  delegate_review_files_exec "$RUNNER" "$@" || {
    RC=$?
    [ "$RC" -ne 2 ] || echo "Usage: codex-review-exec.sh --files <worktree> <goal_file> <files> [inputs_dir] [--range <diff_range>]"
    exit "$RC"
  }
else
  delegate_review_diff_exec "$RUNNER" "$@" || {
    RC=$?
    [ "$RC" -ne 2 ] || echo "Usage: codex-review-exec.sh <worktree> <goal1> <diff1> [<goal2> <diff2> ...] [--inputs-dir <dir>]"
    exit "$RC"
  }
fi

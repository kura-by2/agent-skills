#!/usr/bin/env bash
# Usage: codex-exec.sh <worktree> <task_path> <model> <context_prompt> [add_dir ...]
# impl 委譲の codex backend 実行部分（codex exec を起動）。impl-exec.sh から呼ばれる。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORKTREE="${1:-}"
TASK_PATH="${2:-}"
MODEL="${3:-}"
CONTEXT_PROMPT="${4:-}"
shift 4
ADD_DIRS=("$@")

delegate_run_codex "$WORKTREE" "$TASK_PATH" "$MODEL" "$CONTEXT_PROMPT" \
  "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"

#!/bin/bash
# Usage: codex-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/model-cache.sh"

WORKTREE="${1:-}"
TASK="${2:-}"
INPUTS_DIR="${3:-}"
SELECTED_CONTEXT_FILE="${4:-}"

if [ -z "$WORKTREE" ] || [ -z "$TASK" ]; then
  echo "Usage: codex-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

delegate_ensure_model_cache codex

TASK_PATH="$TASK"
if [ -n "$INPUTS_DIR" ]; then
  TASK_PATH="$INPUTS_DIR/$TASK"
fi

ADD_DIR_ARGS=()
if [ -n "$INPUTS_DIR" ]; then
  ADD_DIR_ARGS+=(--add-dir "$INPUTS_DIR")
fi

CONTEXT_PROMPT=""
if [ -n "$SELECTED_CONTEXT_FILE" ] && [ -f "$SELECTED_CONTEXT_FILE" ]; then
  while IFS= read -r context_path || [ -n "$context_path" ]; do
    context_path="$(printf '%s' "$context_path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -z "$context_path" ] || [[ "$context_path" == \#* ]]; then
      continue
    fi
    if [ ! -f "$context_path" ] || [[ "${context_path,,}" != *.md && "${context_path,,}" != *.markdown ]]; then
      printf 'warning: selected delegate context is not a Markdown file: %s\n' "$context_path" >&2
      continue
    fi
    context_path="$(readlink -f "$context_path")"
    CONTEXT_PROMPT+=$'\n- '"$context_path"
    ADD_DIR_ARGS+=(--add-dir "$(dirname "$context_path")")
  done < "$SELECTED_CONTEXT_FILE"
fi

if [ -n "$CONTEXT_PROMPT" ]; then
  CONTEXT_PROMPT=$'\n現在のタスクに適用する追加資料は次のとおりです。これらだけを読んでルールを適用し、最終報告に「適用した追加資料」としてファイルパスを明記してください。'"$CONTEXT_PROMPT"
fi

if [ "${DELEGATE_SKIP_EXEC:-}" = "1" ]; then
  printf 'delegate: skipped codex exec because DELEGATE_SKIP_EXEC=1\n' >&2
  exit 0
fi

codex exec -C "$WORKTREE" \
  "${ADD_DIR_ARGS[@]}" \
  --dangerously-bypass-approvals-and-sandbox \
  "${TASK_PATH} を読んで対応してください。${CONTEXT_PROMPT}" \
  < /dev/null

#!/usr/bin/env bash
# Codex backend shared execution for implementation, read-only investigation, and review.

DELEGATE_CODEX_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DELEGATE_CODEX_COMMON_DIR/model-cache.sh"

delegate_codex_exec() (
  local PROFILE="${1:-}"
  local MODEL="${2:-}"
  local WORKTREE="${3:-}"
  local TASK="${4:-}"
  local INPUTS_DIR="${5:-}"
  local SELECTED_CONTEXT_FILE="${6:-}"

  if [ -z "$PROFILE" ] || [ -z "$MODEL" ] || [ -z "$WORKTREE" ] || [ -z "$TASK" ]; then
    printf 'error: delegate codex exec requires <profile> <model> <worktree> <task_file>\n' >&2
    return 1
  fi

  local CODEX_CONFIG_HOME="${CODEX_HOME:-${HOME}/.codex}"
  if [ ! -f "$CODEX_CONFIG_HOME/$PROFILE.config.toml" ]; then
    printf 'error: Codex profile not found: %s/%s.config.toml (set CODEX_HOME to the configured Codex home)\n' "$CODEX_CONFIG_HOME" "$PROFILE" >&2
    return 1
  fi

  delegate_ensure_model_cache codex || return $?

  local TASK_PATH="$TASK"
  if [ -n "$INPUTS_DIR" ]; then
    TASK_PATH="$INPUTS_DIR/$TASK"
  fi
  if [ ! -f "$TASK_PATH" ]; then
    printf 'error: task file not found: %s\n' "$TASK_PATH" >&2
    return 1
  fi

  local ADD_DIR_ARGS=()
  if [ -n "$INPUTS_DIR" ]; then
    ADD_DIR_ARGS+=(--add-dir "$INPUTS_DIR")
  fi

  local CONTEXT_PROMPT=""
  if [ -n "$SELECTED_CONTEXT_FILE" ] && [ -f "$SELECTED_CONTEXT_FILE" ]; then
    local context_path
    while IFS= read -r context_path || [ -n "$context_path" ]; do
      context_path="$(printf '%s' "$context_path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      if [ -z "$context_path" ] || [[ "$context_path" == \#* ]]; then
        continue
      fi
      if [ ! -f "$context_path" ] || [[ "${context_path,,}" != *.md && "${context_path,,}" != *.markdown ]]; then
        printf 'warning: selected delegate context is not a Markdown file: %s\n' "$context_path" >&2
        continue
      fi
      CONTEXT_PROMPT+=$'\n- '"$context_path"
      ADD_DIR_ARGS+=(--add-dir "$(dirname "$context_path")")
    done < "$SELECTED_CONTEXT_FILE"
  fi
  if [ -n "$CONTEXT_PROMPT" ]; then
    CONTEXT_PROMPT=$'\n現在のタスクに適用する追加資料は次のとおりです。これらだけを読んでルールを適用し、最終報告に「適用した追加資料」としてファイルパスを明記してください。'"$CONTEXT_PROMPT"
  fi

  local ROLE_PROMPT=""
  if [ "$PROFILE" = "sub" ] || [ "$PROFILE" = "review" ]; then
    ROLE_PROMPT=" この委譲は読み取り専用です。ファイルの作成・編集・削除、コミット、外部状態の変更を行わず、調査またはレビュー結果だけを応答してください。"
  fi

  if [ "${DELEGATE_SKIP_EXEC:-}" = "1" ]; then
    printf 'delegate: skipped codex exec because DELEGATE_SKIP_EXEC=1\n' >&2
    return 0
  fi

  local OUTPUT_FILE STDOUT_FILE STDERR_FILE
  OUTPUT_FILE="$(mktemp)"
  STDOUT_FILE="$(mktemp)"
  STDERR_FILE="$(mktemp)"
  trap 'rm -f "$OUTPUT_FILE" "$STDOUT_FILE" "$STDERR_FILE"' EXIT
  local RC=0

  local SANDBOX="workspace-write"
  case "$PROFILE" in sub|review) SANDBOX="read-only" ;; esac

  if codex exec --profile "$PROFILE" --dangerously-bypass-hook-trust -C "$WORKTREE" \
    --model "$MODEL" \
    "${ADD_DIR_ARGS[@]}" \
    --sandbox "$SANDBOX" \
    "${TASK_PATH} を読んで対応してください。${ROLE_PROMPT}${CONTEXT_PROMPT}" \
    > "$STDOUT_FILE" 2> "$STDERR_FILE" < /dev/null; then
    :
  else
    RC=$?
  fi

  cat "$STDOUT_FILE"
  cat "$STDERR_FILE" >&2
  cat "$STDOUT_FILE" "$STDERR_FILE" > "$OUTPUT_FILE"
  delegate_maybe_emit_fallback_suggest "$MODEL" "$OUTPUT_FILE" "$RC"
  return "$RC"
)

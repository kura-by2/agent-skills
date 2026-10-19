#!/usr/bin/env bash
# Resolve routing.tsv once and invoke the selected backend.

DELEGATE_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DELEGATE_COMMON_DIR/model-cache.sh"
source "$DELEGATE_COMMON_DIR/codex-common.sh"
source "$DELEGATE_COMMON_DIR/claude-common.sh"

delegate_exec_for_task_type() {
  local TASK_TYPE="${1:-}"
  local CODEX_PROFILE="${2:-}"
  shift 2

  local ROUTE BACKEND AGENT MODEL
  ROUTE="$(delegate_route_for_task_type "$TASK_TYPE")" || return 1
  IFS=$'\037' read -r BACKEND AGENT MODEL <<< "${ROUTE//$'\t'/$'\037'}"

  case "$BACKEND" in
    codex)
      delegate_codex_exec "$CODEX_PROFILE" "$MODEL" "$@"
      ;;
    claude)
      delegate_claude_exec "$AGENT" "$@"
      ;;
  esac
}

#!/usr/bin/env bash
# Resolve routing.tsv once and invoke the backend required by the entrypoint.

DELEGATE_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DELEGATE_COMMON_DIR/model-cache.sh"
source "$DELEGATE_COMMON_DIR/codex-common.sh"
source "$DELEGATE_COMMON_DIR/claude-common.sh"

delegate_mark_sync_deadline_delegate() {
  local session="${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-}}"
  [ -n "$session" ] || return 0
  mkdir -p /tmp/claude-sync-deadline 2>/dev/null || return 0
  : > "/tmp/claude-sync-deadline/$session.delegate" 2>/dev/null || true
}

delegate_exec_for_backend() {
  local TASK_TYPE="${1:-}"
  local REQUIRED_BACKEND="${2:-}"
  local ROLE="${3:-}"
  shift 3

  delegate_mark_sync_deadline_delegate

  local ROUTE BACKEND AGENT MODEL
  ROUTE="$(delegate_route_for_task_type "$TASK_TYPE")" || return 1
  IFS=$'\037' read -r BACKEND AGENT MODEL <<< "${ROUTE//$'\t'/$'\037'}"

  if [ "$BACKEND" != "$REQUIRED_BACKEND" ]; then
    printf 'error: %s delegate entrypoint requires backend %s, but routing for task_type %s specifies %s\n' \
      "$REQUIRED_BACKEND" "$REQUIRED_BACKEND" "$TASK_TYPE" "$BACKEND" >&2
    return 1
  fi

  case "$BACKEND" in
    codex)
      delegate_codex_exec "$ROLE" "$MODEL" "$@"
      ;;
    claude)
      delegate_claude_exec "$AGENT" "$MODEL" "$@"
      ;;
  esac
}

# Compatibility entrypoint for the existing codex-exec.sh driver.
delegate_exec_for_task_type() {
  local task_type="${1:-}"
  local role="${2:-}"
  shift 2

  delegate_mark_sync_deadline_delegate

  local route backend agent model
  route="$(delegate_route_for_task_type "$task_type")" || return 1
  IFS=$'\037' read -r backend agent model <<< "${route//$'\t'/$'\037'}"
  case "$backend" in
    codex) delegate_codex_exec "$role" "$model" "$@" ;;
    claude) delegate_claude_exec "$agent" "$model" "$@" ;;
  esac
}

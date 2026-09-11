#!/bin/bash
# Usage: claude-impl-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
# 実装委譲用（impl エージェント、書き込み・コミット許可／検証コマンド禁止）。
# codex が使えない場合のフォールバックとして実装を回す。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/claude-common.sh"

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "Usage: claude-impl-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

WORKTREE="$1"
TASK="$2"
INPUTS_DIR="${3:-}"
TASK_PATH="$TASK"
if [ -n "$INPUTS_DIR" ]; then
  TASK_PATH="$INPUTS_DIR/$TASK"
fi

# レビュー自動チェーン用: 実装前の HEAD を記録（git 管理外の作業場所ならチェーンしない）
PRE_HEAD="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"

RC=0
delegate_claude_exec impl "$@" || RC=$?

# 実装委譲は必ずレビューとペアにする（指示内容を正しく反映しているかの goal alignment）。
# 実装が成功しコミットが増えた場合のみ、同じ指示ファイルを goal にしてレビューを自動チェーンする。
# DELEGATE_SKIP_REVIEW=1 でテスト時のみ抑止できる。
if [ "$RC" -eq 0 ] && [ "${DELEGATE_SKIP_REVIEW:-}" != "1" ] && [ -n "$PRE_HEAD" ]; then
  POST_HEAD="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$POST_HEAD" ] && [ "$POST_HEAD" != "$PRE_HEAD" ]; then
    if [ -s /tmp/claude-active-topic ]; then
      printf 'DELEGATE_REVIEW_RANGE\t%s\t%s..%s\n' "$WORKTREE" "$PRE_HEAD" "$POST_HEAD"
    else
      printf 'delegate: chaining review (%s..%s)\n' "${PRE_HEAD:0:7}" "${POST_HEAD:0:7}" >&2
      bash "$SCRIPT_DIR/claude-review-exec.sh" "$WORKTREE" "$TASK_PATH" "$PRE_HEAD..$POST_HEAD" "${INPUTS_DIR:-/tmp/delegate-inputs}" || {
        printf 'delegate: review chain failed (implementation kept, review must be rerun)\n' >&2
        exit 1
      }
    fi
  else
    printf 'delegate: no new commits, review chain skipped\n' >&2
  fi
fi
exit "$RC"

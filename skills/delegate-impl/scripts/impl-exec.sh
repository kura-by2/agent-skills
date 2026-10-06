#!/usr/bin/env bash
# Usage: impl-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]
# 実装委譲（impl エージェント・codex / claude、書き込み・コミット許可／検証コマンド禁止）。
# 委譲ごとに Jev でモデルを選び、同一 backend で2回連続して非0終了したら
# fallback/impl.tsv のもう一方の backend の行のモデルで同じ worktree・同じ指示のまま再実行する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORKTREE="${1:-}"
TASK="${2:-}"
INPUTS_DIR="${3:-}"
SELECTED_CONTEXT_FILE="${4:-}"

if [ -z "$WORKTREE" ] || [ -z "$TASK" ]; then
  echo "Usage: impl-exec.sh <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

delegate_mark_sync_deadline_delegate

TASK_PATH="$TASK"
[ -n "$INPUTS_DIR" ] && TASK_PATH="$INPUTS_DIR/$TASK"
if [ ! -f "$TASK_PATH" ]; then
  printf 'error: task file not found: %s\n' "$TASK_PATH" >&2
  exit 1
fi

# 起動時: model-tiers が1日以上前/不在なら再生成し、impl フォールバック（codex・claude の2行）も作る。
if ! delegate_refresh_tiers_and_fallback impl codex claude; then
  printf 'error: delegate impl cannot run because no model tier is available (fail-closed)\n' >&2
  exit 1
fi

# 主選定: Jev（候補は codex と claude 両方）→ だめなら fallback/impl.tsv の1行目。
RESOLVED="$(delegate_resolve_model impl "$TASK_PATH" codex claude)" || true
if [ -z "$RESOLVED" ]; then
  printf 'error: delegate impl cannot resolve a model and no fallback exists (fail-closed)\n' >&2
  exit 1
fi
IFS=$'\t' read -r BACKEND MODEL <<< "$RESOLVED"

CONTEXT_PROMPT=""
CONTEXT_DIRS=()
delegate_build_context "$SELECTED_CONTEXT_FILE" CONTEXT_PROMPT CONTEXT_DIRS

OUT_FILE="$(mktemp)"
ERR_FILE="$(mktemp)"
STDOUT_ALL="$(mktemp)"
trap 'rm -f "$OUT_FILE" "$ERR_FILE" "$STDOUT_ALL"' EXIT

RC=0

run_once() { # <backend> <model>
  local backend="$1" model="$2" rc=0
  local dirs=()
  [ -n "$INPUTS_DIR" ] && dirs+=("$INPUTS_DIR")
  dirs+=("${CONTEXT_DIRS[@]+"${CONTEXT_DIRS[@]}"}")
  if [ "$backend" = "codex" ]; then
    delegate_run_codex "$WORKTREE" "$TASK_PATH" "$model" "$CONTEXT_PROMPT" \
      "${dirs[@]+"${dirs[@]}"}" > "$OUT_FILE" 2> "$ERR_FILE" || rc=$?
  else
    delegate_run_claude impl "$WORKTREE" "$TASK_PATH" "$model" "$CONTEXT_PROMPT" \
      "$WORKTREE" "${dirs[@]+"${dirs[@]}"}" > "$OUT_FILE" 2> "$ERR_FILE" || rc=$?
  fi
  cat "$OUT_FILE"
  cat "$ERR_FILE" >&2
  cat "$OUT_FILE" >> "$STDOUT_ALL"
  RC="$rc"
}

is_permission() {
  grep -Fq 'DELEGATE_PERMISSION_OUT_OF_SCOPE' "$OUT_FILE" "$ERR_FILE" 2>/dev/null
}

printf 'delegate impl: backend=%s model=%s\n' "$BACKEND" "$MODEL" >&2
run_once "$BACKEND" "$MODEL"
if [ "$RC" -ne 0 ] && ! is_permission; then
  # 1回目の失敗 → 同じモデルでもう1回。
  printf 'delegate impl: retry (same model) backend=%s model=%s\n' "$BACKEND" "$MODEL" >&2
  run_once "$BACKEND" "$MODEL"
  if [ "$RC" -ne 0 ] && ! is_permission; then
    # 2回連続失敗 → fallback/impl.tsv のもう一方の backend で再実行。
    if [ "$BACKEND" = "codex" ]; then OTHER="claude"; else OTHER="codex"; fi
    if OTHER_ROW="$(delegate_fallback_model impl "$OTHER")"; then
      IFS=$'\t' read -r OBACKEND OMODEL <<< "$OTHER_ROW"
      printf 'delegate impl: switch backend=%s model=%s\n' "$OBACKEND" "$OMODEL" >&2
      run_once "$OBACKEND" "$OMODEL"
    else
      printf 'warning: delegate impl has no fallback row for backend %s; not switching\n' "$OTHER" >&2
    fi
  fi
fi

REVIEW_FILES="$(awk -F '\t' '$1 == "DELEGATE_CHANGED_FILE" && $2 ~ /^\// && NF == 2 { print $2 }' "$STDOUT_ALL" | sort -u)"
if [ -n "$REVIEW_FILES" ]; then
  while IFS= read -r review_file; do
    printf 'DELEGATE_REVIEW_FILE\t%s\n' "$review_file"
  done <<< "$REVIEW_FILES"
else
  printf 'DELEGATE_REVIEW_UNRESOLVED\t%s\tno_declared_files\n' "$WORKTREE"
fi

exit "$RC"

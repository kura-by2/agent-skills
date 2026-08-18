#!/bin/bash
# Usage: claude-exec.sh <agent> <model_selector> <worktree> <task_file> [inputs_dir] [selected_context_file]
# ファンネル（調査/設計/レビュー委譲）の実行エンジン（claude 版）。
#
# 重要:
#   - agent は sub または review に限定する。どちらも .claude/agents 側で
#     Edit/Write/MultiEdit を禁止する。
#   - cd はしない。作業対象 worktree は --add-dir で渡し、プロンプトで作業ルートを明示する。
#     cwd は呼び出し元（プロジェクトルート）のままなので、git 操作が cwd 側リポジトリに
#     当たらないよう、プロンプトで `git -C <worktree>` を強制する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/model-cache.sh"

AGENT="${1:-}"
MODEL_SELECTOR="${2:-}"
WORKTREE="${3:-}"
TASK="${4:-}"
INPUTS_DIR="${5:-}"
SELECTED_CONTEXT_FILE="${6:-}"

if [ -z "$AGENT" ] || [ -z "$MODEL_SELECTOR" ] || [ -z "$WORKTREE" ] || [ -z "$TASK" ]; then
  echo "Usage: claude-exec.sh <agent> <model_selector> <worktree> <task_file> [inputs_dir] [selected_context_file]"
  exit 1
fi

case "$AGENT" in
  sub|review)
    ;;
  *)
    printf 'error: unsupported claude delegate agent: %s\n' "$AGENT" >&2
    exit 1
    ;;
esac

delegate_ensure_model_cache claude
MODEL="$(delegate_select_model claude "$MODEL_SELECTOR")"

TASK_PATH="$TASK"
if [ -n "$INPUTS_DIR" ]; then
  TASK_PATH="$INPUTS_DIR/$TASK"
fi

ADD_DIR_ARGS=(--add-dir "$WORKTREE")
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
  printf 'delegate: skipped claude exec because DELEGATE_SKIP_EXEC=1\n' >&2
  exit 0
fi

OUTPUT_FILE="$(mktemp)"
STDOUT_FILE="$(mktemp)"
STDERR_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE" "$STDOUT_FILE" "$STDERR_FILE"' EXIT
RC=0
PROMPT="作業対象のリポジトリは ${WORKTREE} です。${TASK_PATH} を読み、${WORKTREE} 内のファイルに対して対応してください。git 操作はすべて 'git -C ${WORKTREE} ...' で行い、それ以外のリポジトリやディレクトリには触れないこと。自分の権限範囲外の作業を求められたら固定文言 DELEGATE_PERMISSION_OUT_OF_SCOPE だけを出して終了すること。${CONTEXT_PROMPT}"

if ! claude -p "$PROMPT" \
  --agent "$AGENT" \
  --model "$MODEL" \
  "${ADD_DIR_ARGS[@]}" \
  --dangerously-skip-permissions \
  > "$STDOUT_FILE" 2> "$STDERR_FILE" < /dev/null; then
  RC="${PIPESTATUS[0]}"
fi

cat "$STDOUT_FILE"
cat "$STDERR_FILE" >&2
cat "$STDOUT_FILE" "$STDERR_FILE" > "$OUTPUT_FILE"
delegate_maybe_emit_fallback_suggest "$MODEL" "$OUTPUT_FILE" "$RC"
exit "$RC"

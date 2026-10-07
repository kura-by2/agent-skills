#!/usr/bin/env bash
# LLM による短文要約を設定から隔離して実行する共通スクリプト。
# このディレクトリに置き、どのスキルからも呼ぶ。
#
# 使い方:
#   script.sh <prompt>
#   渡されたプロンプトを、要約モデルで隔離実行し、応答をそのまま返す。
#   要約プロンプトの文面・応答の妥当性判定は呼び出し側の責務。
#
# 隔離実行:
#   呼び出し元プロジェクトの設定・hooks・MCP ツール・CLAUDE.md を読み込ませない
#   （空の作業ディレクトリ・setting-sources なし・strict-mcp-config）。
#
# モデルの決め方:
#   要約は責務が一定なので毎回は判定しない。保存ファイル model.txt（git 追跡外）が
#   SUMMARIZE_MODEL_MAX_AGE_SECONDS 以上古いか不在のときだけ選び直し、それ以外は model.txt のモデルを使う。
#
# 出力・終了コード:
#   stdout に LLM の応答をそのまま出し、LLM の終了コードを返す。
#   モデルを決められないときは非0で終了し、理由を stderr に出す。
set -u

SUMMARIZE_MODEL_MAX_AGE_SECONDS=86400 # 要約モデルの鮮度（1日）
SUMMARIZE_JEV_MIN_CONFIDENCE=0.6      # 要約モデル選択で要求する Jev の最低確信度
SUMMARIZE_JEV_STATE='要約タスクに使うモデルを選ぶ。' # Jev に渡す状態（要約文）
SUMMARIZE_JEV_INSTRUCTIONS='要約するのに適切なモデルはどれ？' # 固定の問い

# このスクリプトの実体があるディレクトリ。symlink 経由で呼ばれても実体から解決する。
SUMMARIZE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARIZE_MODEL_FILE="$SUMMARIZE_DIR/model.txt"
# 共通スクリプト同士の呼び出し。要約モデルの候補元（llm-models）と Jev 判定。
SUMMARIZE_LLM_MODELS_SCRIPT="$SUMMARIZE_DIR/../llm-models/script.sh"
SUMMARIZE_LLM_MODELS_FILE="$SUMMARIZE_DIR/../llm-models/llm-models.tsv"
SUMMARIZE_JEV_CHOICE_SCRIPT="$SUMMARIZE_DIR/../jev-choice.sh"

summarize_is_fresh() {
  local f="$1" now mtime
  [ -f "$f" ] || return 1
  now="$(date +%s)"
  mtime="$(date -r "$f" +%s 2>/dev/null)" || return 1
  [ "$((now - mtime))" -lt "$SUMMARIZE_MODEL_MAX_AGE_SECONDS" ]
}

# 保存済みの要約モデル名を1行で返す。ファイル不在・空なら非0。
summarize_read_model() {
  local model
  [ -f "$SUMMARIZE_MODEL_FILE" ] || return 1
  model="$(sed -n '1{s/^[[:space:]]*//; s/[[:space:]]*$//; p;}' "$SUMMARIZE_MODEL_FILE")"
  [ -n "$model" ] || return 1
  printf '%s\n' "$model"
}

# 要約モデルの選択肢（claude backend）を "model<TAB>説明" で出す。
# summarize は claude で動くので候補は llm-models.tsv の claude 行に限る。
summarize_candidates() {
  [ -f "$SUMMARIZE_LLM_MODELS_FILE" ] || return 1
  awk -F '\t' '$0 !~ /^#/ && NF >= 3 && $1 == "claude" { print $2 "\t" $3 }' "$SUMMARIZE_LLM_MODELS_FILE"
}

# 固定の問いで Jev に要約モデルを1つ選ばせる。標準出力にモデル名。失敗・低確信度は非0。
summarize_select_model() {
  local candidates out choice conf
  candidates="$(summarize_candidates)" || return 1
  [ -n "$candidates" ] || return 1
  out="$(printf '%s' "$candidates" | "$SUMMARIZE_JEV_CHOICE_SCRIPT" \
    --min-confidence "$SUMMARIZE_JEV_MIN_CONFIDENCE" \
    "$SUMMARIZE_JEV_STATE" "$SUMMARIZE_JEV_INSTRUCTIONS" 2>/dev/null)" || return 1
  IFS=$'\t' read -r choice conf <<< "$out"
  [ -n "$choice" ] || return 1
  printf '%s\n' "$choice"
}

# 要約モデルを24時間固定で確保し、標準出力にモデル名を返す。
# model.txt が新しければそのまま使う。古い/不在なら選び直す:
#   1. llm-models を最新化する（失敗しても続行し、既存の一覧を使う）。
#   2. claude 候補を Jev で選び、model.txt に保存する。
# 選び直しに失敗（一覧なし・Jev 失敗・低確信度含む）したら前回値を使う。
# 前回値も無ければ非0で終了し、継続方法を stderr に出す。
summarize_ensure_model() {
  local prev chosen
  if summarize_is_fresh "$SUMMARIZE_MODEL_FILE"; then
    summarize_read_model && return 0
  fi

  prev="$(summarize_read_model 2>/dev/null)" || prev=""

  "$SUMMARIZE_LLM_MODELS_SCRIPT" >/dev/null 2>&1 || true

  if chosen="$(summarize_select_model)"; then
    printf '%s\n' "$chosen" > "$SUMMARIZE_MODEL_FILE"
    printf '%s\n' "$chosen"
    return 0
  fi

  if [ -n "$prev" ]; then
    printf 'warning: could not reselect summary model via Jev; keeping previous (%s)\n' "$prev" >&2
    printf '%s\n' "$prev"
    return 0
  fi

  printf 'error: cannot determine the summary model. Write a model name (e.g. a claude model) into %s to continue.\n' \
    "$SUMMARIZE_MODEL_FILE" >&2
  return 1
}

prompt="${1:-}"

model="$(summarize_ensure_model)" || exit 1

workdir="$(mktemp -d)" || exit 1
( cd "$workdir" && claude -p "$prompt" --model "$model" \
    --setting-sources '' --strict-mcp-config < /dev/null 2>/dev/null )
rc=$?
rmdir "$workdir" 2>/dev/null || true
exit "$rc"

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
#   要約モデルの用意は model.sh に委ねる（24時間固定・Jev での選び直し・前回値）。
#
# 出力・終了コード:
#   stdout に LLM の応答をそのまま出し、LLM の終了コードを返す。
#   モデルを決められないときは非0で終了し、理由を stderr に出す。
set -u

# このスクリプトの実体があるディレクトリ。symlink 経由で呼ばれても実体から解決する。
SUMMARIZE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARIZE_MODEL_SCRIPT="$SUMMARIZE_DIR/model.sh"

prompt="${1:-}"

model="$("$SUMMARIZE_MODEL_SCRIPT")" || exit 1

workdir="$(mktemp -d)" || exit 1
( cd "$workdir" && claude -p "$prompt" --model "$model" \
    --setting-sources '' --strict-mcp-config < /dev/null 2>/dev/null )
rc=$?
rmdir "$workdir" 2>/dev/null || true
exit "$rc"

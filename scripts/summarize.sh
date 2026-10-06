#!/usr/bin/env bash
# LLM による短文要約を設定から隔離して実行する共通スクリプト。リポジトリ直下に置き、
# どのスキルからも呼ぶ。
#
# 使い方:
#   summarize.sh <prompt> [model]
#   model 省略時は環境変数 DELEGATE_SUMMARY_MODEL（既定 haiku）を使う。
#
# 呼び出し元プロジェクトの設定・hooks・MCP ツール・CLAUDE.md を読み込ませない
# （空の作業ディレクトリ・setting-sources なし・strict-mcp-config）。
#
# 出力・終了コード:
#   stdout に LLM の応答をそのまま出し、LLM の終了コードを返す。
#   要約プロンプトの文面・応答の妥当性判定は呼び出し側の責務。
set -u

prompt="${1:-}"
model="${2:-${DELEGATE_SUMMARY_MODEL:-haiku}}"

workdir="$(mktemp -d)" || exit 1
( cd "$workdir" && claude -p "$prompt" --model "$model" \
    --setting-sources '' --strict-mcp-config < /dev/null 2>/dev/null )
rc=$?
rmdir "$workdir" 2>/dev/null || true
exit "$rc"

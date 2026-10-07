#!/usr/bin/env bash
# LLM による短文要約を設定から隔離して実行する共通スクリプト。リポジトリ直下に置き、
# どのスキルからも呼ぶ。
#
# 使い方:
#   summarize.sh <prompt> <model>
#   model は必須。どのモデルで要約するかは呼び出し側が決めて渡す。
#
# 呼び出し元プロジェクトの設定・hooks・MCP ツール・CLAUDE.md を読み込ませない
# （空の作業ディレクトリ・setting-sources なし・strict-mcp-config）。
#
# 出力・終了コード:
#   stdout に LLM の応答をそのまま出し、LLM の終了コードを返す。
#   要約プロンプトの文面・応答の妥当性判定は呼び出し側の責務。
set -u

prompt="${1:-}"
model="${2:-}"
if [ -z "$model" ]; then
  printf 'error: summarize.sh requires a model as the second argument\n' >&2
  exit 2
fi

workdir="$(mktemp -d)" || exit 1
( cd "$workdir" && claude -p "$prompt" --model "$model" \
    --setting-sources '' --strict-mcp-config < /dev/null 2>/dev/null )
rc=$?
rmdir "$workdir" 2>/dev/null || true
exit "$rc"

#!/usr/bin/env bash
# Jev の choice 判定を行う共通スクリプト。リポジトリ直下に置き、どのスキルからも呼ぶ。
#
# 使い方:
#   jev-choice.sh <state(要約文)> <instructions> [choices_file]
#   選択肢は "名前<TAB>説明" の行で、choices_file またはファイル省略時は stdin から渡す。
#
# 出力・終了コード:
#   成功時: stdout に "choice<TAB>confidence"、終了コード 0。
#   失敗時: stderr に失敗理由1行（no_key / none / timeout / http_error）、終了コード 非0。
#   閾値判定は行わない（呼び出し側の責務）。
#
# 接続先は api.typesafe.ai に固定する（上書き不可）。鍵の値と送信内容はログ・出力に書かない。
set -u

JEV_URL="https://api.typesafe.ai/v1/systemone"
JEV_MODEL="jev-latest"
JEV_TIMEOUT="${DELEGATE_JEV_TIMEOUT:-3}"

summary="${1:-}"
instructions="${2:-}"
choices_file="${3:-}"

fail() { printf '%s\n' "$1" >&2; exit 1; }

key="${JEV_API_KEY:-}"
[ -n "$key" ] || fail no_key

if [ -n "$choices_file" ]; then
  raw="$(cat "$choices_file")" || fail none
else
  raw="$(cat)"
fi

# "名前<TAB>説明" の行を criteria（名前→説明）の JSON object にする。
criteria="$(printf '%s' "$raw" | jq -R -s '
  split("\n") | map(select(length > 0) | split("\t")) | map({(.[0]): (.[1] // "")}) | add // {}
')" || fail none
[ -n "$criteria" ] && [ "$criteria" != "{}" ] || fail none

if ! body="$(jq -n --arg state "$summary" --arg model "$JEV_MODEL" \
  --arg instr "$instructions" --argjson criteria "$criteria" '
  {
    state: $state,
    model: $model,
    questions: { route: { type: "choice", instructions: $instr, criteria: $criteria } }
  }')"; then
  fail http_error
fi

resp="$(curl -fsS --max-time "$JEV_TIMEOUT" \
  -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
  -X POST "$JEV_URL" -d "$body" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 28 ]; then fail timeout; else fail http_error; fi
fi

if ! out="$(printf '%s' "$resp" | jq -e -r '
  .answers.route
  | select(.choice != null and (.confidence | type) == "number")
  | "\(.choice)\t\(.confidence)"
' 2>/dev/null)"; then
  fail http_error
fi

printf '%s\n' "$out"

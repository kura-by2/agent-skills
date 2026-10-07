#!/usr/bin/env bash
# Jev の choice 判定を行う共通スクリプト。リポジトリ直下に置き、どのスキルからも呼ぶ。
#
# 使い方:
#   jev-choice.sh [--min-confidence N] <state(要約文)> <instructions> [choices_file]
#   選択肢は "名前<TAB>説明" の行で、choices_file またはファイル省略時は stdin から渡す。
#   --min-confidence N: Jev の confidence が N 未満なら低確信度として失敗扱いにする。
#                       省略時は閾値判定をしない。
#
# 出力・終了コード:
#   成功時: stdout に "choice<TAB>confidence"、終了コード 0。
#   失敗時: stderr に失敗理由1行（no_key / none / timeout / http_error / low_confidence）、
#           終了コード 非0。
#
# 接続先は api.typesafe.ai に固定する（上書き不可）。鍵の値と送信内容はログ・出力に書かない。
set -u

JEV_URL="https://api.typesafe.ai/v1/systemone"
JEV_MODEL="jev-latest"
JEV_TIMEOUT="${DELEGATE_JEV_TIMEOUT:-3}"

min_confidence=""
while [ $# -gt 0 ]; do
  case "$1" in
    --min-confidence) min_confidence="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

summary="${1:-}"
instructions="${2:-}"
choices_file="${3:-}"

# --- デバッグ用: Jev の応答を記録する（本体の判定・出力・終了コードには影響しない） ---
# 要約モデルの選び直しが low_confidence で失敗する原因を追うための一時的な仕掛け。
# 呼び出し元が stderr を捨てても見られるよう、/tmp のファイルに 1 呼び出し 1 行の JSON で追記する。
# 鍵（JEV_API_KEY）と state（要約文）は記録しない。
DEBUG_LOG="/tmp/jev-choice-debug.log"
dbg_names="[]"      # 候補の名前一覧（説明文は含めない）
dbg_route="null"    # HTTP 応答の .answers.route 全体
dbg_resp_head="null" # JSON 解釈不能・HTTP 失敗時に残す応答本文の先頭

debug_log() {
  # デバッグ用: 判定結果を 1 行追記する。記録の失敗で本体を止めないよう握りつぶす。
  jq -n -c \
    --arg time "$(date -Is 2>/dev/null)" \
    --arg instructions "$instructions" \
    --argjson choices "$dbg_names" \
    --argjson route "$dbg_route" \
    --arg min_confidence "$min_confidence" \
    --arg decision "$1" \
    --argjson response_head "$dbg_resp_head" \
    '{time: $time, instructions: $instructions, choices: $choices,
      route: $route, min_confidence: $min_confidence,
      decision: $decision, response_head: $response_head}' \
    >> "$DEBUG_LOG" 2>/dev/null || true
}

fail() { debug_log "$1"; printf '%s\n' "$1" >&2; exit 1; }

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

# デバッグ用: 候補の名前一覧を記録に残す（説明文は含めない）。
dbg_names="$(printf '%s' "$criteria" | jq -c 'keys' 2>/dev/null || printf '[]')"

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

# デバッグ用: 応答から .answers.route 全体と本文先頭を控える。
# route が取れれば choice・confidence・確率分布などの付随情報もそのまま残る。
dbg_route="$(printf '%s' "$resp" | jq -c '.answers.route' 2>/dev/null || printf 'null')"
dbg_resp_head="$(printf '%s' "$resp" | head -c 500 | jq -R -s '.' 2>/dev/null || printf 'null')"

if ! out="$(printf '%s' "$resp" | jq -e -r '
  .answers.route
  | select(.choice != null and (.confidence | type) == "number")
  | "\(.choice)\t\(.confidence)"
' 2>/dev/null)"; then
  fail http_error
fi

# 閾値指定時は confidence（out の2列目）を数値として比較し、N 未満なら低確信度で失敗。
if [ -n "$min_confidence" ]; then
  conf="${out#*$'\t'}"
  awk -v c="$conf" -v m="$min_confidence" 'BEGIN { exit !((c + 0) >= (m + 0)) }' || fail low_confidence
fi

debug_log ok
printf '%s\n' "$out"

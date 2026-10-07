#!/usr/bin/env bash
# llm-models.json から Jev の候補 TSV を出す共通スクリプト。llm-models/ 直下に置き、どのスキルからも呼ぶ。
# 最新化はしない（必要なら呼び出し側が先に llm-models/script.sh を呼ぶ）。
#
# 使い方:
#   criteria.sh <backend>...
#   指定した backend 群のモデルを "model<TAB>説明" の行で stdout に出す（Jev の criteria）。
#   説明は公式の1行説明に、claude の comparison（比較表の値）を「列名: 値」として列順に "; " で連ねた
#   文字列にする。codex は comparison を持たないので1行説明だけになる。
#
# 出力・終了コード:
#   成功時: stdout に候補行（該当モデルが無ければ空）、終了コード 0。
#   backend 未指定・一覧ファイル不在: 非0。
set -u

# このスクリプトの実体があるディレクトリ。symlink 経由で呼ばれても実体から解決する。
CRITERIA_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRITERIA_LLM_MODELS_FILE="$CRITERIA_DIR/llm-models.json"

if [ "$#" -lt 1 ]; then
  printf 'error: criteria.sh requires at least one backend\n' >&2
  exit 1
fi
if [ ! -f "$CRITERIA_LLM_MODELS_FILE" ]; then
  printf 'error: llm-models list not found: %s\n' "$CRITERIA_LLM_MODELS_FILE" >&2
  exit 1
fi

jq -r '
  .[]
  | select(.backend as $b | $ARGS.positional | index($b))
  | .model + "\t"
    + ( ( [ .description ] + ( (.comparison // {}) | to_entries | map("\(.key): \(.value)") ) )
        | map(select(. != null and . != "")) | join("; ") )
' "$CRITERIA_LLM_MODELS_FILE" --args "$@"

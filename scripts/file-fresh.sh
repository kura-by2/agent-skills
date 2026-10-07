#!/usr/bin/env bash
# ファイルの鮮度を判定する共通スクリプト。リポジトリ直下に置き、どのスキルからも呼ぶ。
#
# 使い方:
#   file-fresh.sh <path> <max_age_seconds>
#   path の更新からの経過秒が max_age_seconds 未満なら 0、古い/不在なら 1。stdout には何も出さない。
#   境界は「経過秒 == max_age_seconds は古い扱い」（経過秒 < max_age_seconds のときだけ新しい）。
#
# 出力・終了コード:
#   新しい: 終了コード 0。古い/不在/引数不足: 終了コード 1。出力はしない。
set -u

path="${1:-}"
max_age="${2:-}"
[ -n "$path" ] && [ -n "$max_age" ] || exit 1
[ -f "$path" ] || exit 1
now="$(date +%s)"
mtime="$(date -r "$path" +%s 2>/dev/null)" || exit 1
[ "$((now - mtime))" -lt "$max_age" ]

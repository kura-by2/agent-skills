#!/usr/bin/env bash
# Usage: list-context.sh [summary最大文字数]
# index.md（Markdownテーブル）を列幅を揃えた表で出力する。
# summary は長いので 1 行に収まるよう切り詰める（詳細は load で見る）。
# 無ければ rebuild-index.sh での生成を促す。
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/context-dir.sh"
IDX="$DIR/index.md"
export SUM_MAX="${1:-60}"  # summary の最大文字数

if [ ! -f "$IDX" ]; then
  echo "index.md がありません。bash $(dirname "$0")/rebuild-index.sh で生成してください。" >&2
  exit 1
fi

# 1) md テーブルを tab 区切りへ（md装飾除去）  2) perl で summary を文字単位 truncate  3) 桁揃え
awk -F' *\\| *' '
  /^\|/ {
    if ($2 == "topic" || $2 ~ /^-+$/) next
    summary=$5; gsub(/\*\*|`/, "", summary)
    printf "%s\t%s\t%s\t%s\n", $2, ($3==""?"-":$3), ($4==""?"-":$4), summary
  }
' "$IDX" \
| perl -CSDA -ne '
    chomp; my @c = split /\t/, $_, 4;
    my $m = $ENV{SUM_MAX};
    $c[3] = substr($c[3], 0, $m-1) . "\x{2026}" if length($c[3]) > $m;
    print join("\t", @c), "\n";
  ' \
| { printf 'topic\tupdated\tlast_loaded\tsummary\n'; cat; } | column -t -s$'\t'

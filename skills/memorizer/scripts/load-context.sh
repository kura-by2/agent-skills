#!/bin/bash
# Usage: load-context.sh <topic...>
# 指定トピックの存在するものを last_loaded 更新して読むべき .md のパスを出力する。
# 見つからないトピックは MISSING:<topic> を出力する。
set -euo pipefail

DIR="./memory/contexts"
today=$(date +%F)

seen=" "
order=()

queue() {
  local t="$1"
  case "$seen" in *" $t "*) return ;; esac
  seen="$seen$t "
  local f="$DIR/$t.md"
  if [ ! -f "$f" ]; then
    echo "MISSING:$t"
    return
  fi
  order+=("$t")
}

for t in "$@"; do
  queue "$t"
done

for t in "${order[@]}"; do
  f="$DIR/$t.md"
  if [ "$(head -n1 "$f")" != "---" ]; then
    # フロントマター欠落ファイルも last_loaded を必ず記録できるよう合成して前置する
    mtime=$(date +%F -r "$f")
    tmp=$(mktemp)
    {
      printf -- '---\ntopic: %s\nupdated: %s\nlast_loaded: %s\n---\n\n' "$t" "$mtime" "$today"
      cat "$f"
    } > "$tmp"
    mv "$tmp" "$f"
  elif grep -q '^last_loaded:' "$f"; then
    perl -pi -e "s/^last_loaded:.*/last_loaded: $today/" "$f"
  else
    perl -pi -e 'if (!$done && /^---$/) { $_ .= "last_loaded: '"$today"'\n"; $done = 1 }' "$f"
  fi
  echo "$f"
done

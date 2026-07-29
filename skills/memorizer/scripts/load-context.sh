#!/bin/bash
# Usage: load-context.sh <topic...>
# 指定トピックと depends_on を再帰解決し、存在するものを last_loaded 更新して
# 読むべき .md のパスを依存順（依存先 → 依存元）に出力する。
# 見つからないトピックは MISSING:<topic> を出力する。
set -euo pipefail

DIR="./memory/contexts"
today=$(date +%F)

seen=" "
order=()

resolve() {
  local t="$1"
  case "$seen" in *" $t "*) return ;; esac
  seen="$seen$t "
  local f="$DIR/$t.md"
  if [ ! -f "$f" ]; then
    echo "MISSING:$t"
    return
  fi
  local dep
  for dep in $(awk '
    /^depends_on:/{f=1;next}
    f && /^[^[:space:]-]/{f=0}
    f && /^[[:space:]]*-[[:space:]]/{sub(/^[[:space:]]*-[[:space:]]*/,"");print}
  ' "$f"); do
    resolve "$dep"
  done
  order+=("$t")
}

for t in "$@"; do
  resolve "$t"
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
  parent=$(awk -F': *' '/^parent:/{print $2; exit}' "$f")
  if [ -n "${parent:-}" ]; then
    echo "PARENT:$t:$DIR/$parent.md"
  fi
done

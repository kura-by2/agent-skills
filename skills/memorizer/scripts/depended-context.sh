#!/bin/bash
# Usage: depended-context.sh <topic...>
# 指定トピックの depends_on を再帰的にたどり、補足で読む依存先 .md のパスを出力する。
# last_loaded は更新しない。見つからないトピックは MISSING:<topic> を出力する。
set -euo pipefail

DIR="./memory/contexts"

if [ "$#" -eq 0 ]; then
  echo "Usage: depended-context.sh <topic...>" >&2
  exit 1
fi

seen=" "

deps_for() {
  local f="$1"
  awk '
    /^depends_on:/{f=1;next}
    f && /^[^[:space:]-]/{f=0}
    f && /^[[:space:]]*-[[:space:]]/{sub(/^[[:space:]]*-[[:space:]]*/,"");print}
  ' "$f"
}

walk_deps() {
  local t="$1"
  local f="$DIR/$t.md"
  if [ ! -f "$f" ]; then
    echo "MISSING:$t"
    return
  fi

  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$seen" in *" $dep "*) continue ;; esac
    seen="$seen$dep "

    local dep_file="$DIR/$dep.md"
    if [ ! -f "$dep_file" ]; then
      echo "MISSING:$dep"
      continue
    fi

    echo "$dep_file"
    walk_deps "$dep"
  done < <(deps_for "$f")
}

for t in "$@"; do
  walk_deps "$t"
done

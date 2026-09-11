#!/bin/bash
# Usage: scan-skills.sh [targets.md path]
# existing_assets.skills の相対パスは、実行時の CWD を基準に解決する。
# existing_assets.skills 配下の SKILL.md 行数と skill-usage.log の最終利用日を集計する。
# 読み取り専用。100行超、未使用、30日超を決定的に抽出し、内容判断は呼び出し元に委ねる。
set -euo pipefail

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
TARGETS="${1:-$BASE_DIR/targets.md}"
USAGE_LOG="${CLAUDE_PROJECT_DIR:?}/logs/skill-usage.log"
STALE_DAYS=30

if [ ! -f "$TARGETS" ]; then
  echo "targets.md が見つかりません" >&2
  exit 0
fi

get_skill_paths() {
  awk '
    /^existing_assets:[[:space:]]*$/ { assets=1; next }
    assets && /^[^[:space:]]/ { assets=0; skills=0 }
    assets && /^  skills:[[:space:]]*$/ { skills=1; next }
    skills && /^  [A-Za-z0-9_-]+:/ { skills=0 }
    skills && /^[[:space:]]+- / {
      sub(/^[[:space:]]*- /, "")
      gsub(/^['\''"]|['\''"]$/, "")
      print
    }
  ' "$TARGETS"
}

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  pattern="${pattern/#\~/$HOME}"
  matched=0
  while IFS= read -r root; do
    matched=1
    [ -e "$root" ] || continue
    if [ -f "$root" ] && [ "$(basename "$root")" = "SKILL.md" ]; then
      printf '%s\n' "$root"
    elif [ -d "$root" ]; then
      find -L "$root" -type f -name SKILL.md -print
    fi
  done < <(compgen -G "$pattern" || true)
  [ "$matched" -eq 1 ] || echo "警告: existing_assets.skills のパターンに一致する対象がありません: $pattern" >&2
done < <(get_skill_paths) | sort -u > "$TMP"

echo "## SKILL.md 行数"
if [ ! -s "$TMP" ]; then
  echo "(対象なし)"
else
  while IFS= read -r file; do
    printf '%s\t%s\n' "$(wc -l < "$file")" "$file"
  done < "$TMP" | sort -t$'\t' -k1,1nr -k2,2
fi

echo
echo "## 100行超（内容判定が必要）"
oversized=0
while IFS= read -r file; do
  lines=$(wc -l < "$file")
  if [ "$lines" -gt 100 ]; then
    printf '%s\t%s\n' "$lines" "$file"
    oversized=1
  fi
done < "$TMP"
[ "$oversized" -eq 1 ] || echo "(なし)"

echo
echo "## 未使用・30日超"
if [ ! -f "$USAGE_LOG" ]; then
  echo "(skill-usage.log なし: スキップ)"
  exit 0
fi

stale=0
today=$(date +%s)
while IFS= read -r file; do
  skill=$(basename "$(dirname "$file")")
  last=$(awk -F '\t' -v skill="$skill" '$2 == skill { date=$1 } END { print date }' "$USAGE_LOG")
  if [ -z "$last" ]; then
    printf '未使用\t%s\t%s\n' "$skill" "$file"
    stale=1
    continue
  fi
  if last_epoch=$(date -d "$last" +%s 2>/dev/null); then
    age=$(( (today - last_epoch) / 86400 ))
    if [ "$age" -gt "$STALE_DAYS" ]; then
      printf '%s日\t%s\t%s\n' "$age" "$skill" "$file"
      stale=1
    fi
  fi
done < "$TMP"
[ "$stale" -eq 1 ] || echo "(なし)"

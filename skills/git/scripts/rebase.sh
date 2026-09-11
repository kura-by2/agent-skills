#!/usr/bin/env bash
# child ブランチを parent に rebase する。コンフリクト時は abort して報告する。
set -uo pipefail

parent="${1:-}"; child="${2:-}"
[ -z "$parent" ] && { echo "usage: rebase.sh <parent> [child]" >&2; exit 1; }

if [ -n "$child" ]; then
  wt_path=$(git worktree list --porcelain | awk -v b="branch refs/heads/$child" '
    /^worktree /{p=$2} $0==b{print p; exit}')
  [ -z "$wt_path" ] && { echo "worktree not found for branch: $child" >&2; exit 1; }
else
  wt_path=$(pwd)
fi

if git -C "$wt_path" rebase "$parent"; then
  echo "rebased: $(git -C "$wt_path" branch --show-current) onto $parent"
  exit 0
fi

echo "CONFLICT: 以下のファイルでコンフリクト。abort しました。ユーザーに報告して指示を仰ぐこと。" >&2
git -C "$wt_path" diff --name-only --diff-filter=U >&2
git -C "$wt_path" rebase --abort
exit 2

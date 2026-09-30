#!/usr/bin/env bash
# Usage: pr-comments.sh <pr_number|pr_url> [owner/repo]
set -e

ARG1="$1"
ARG2="$2"

if [ -z "$ARG1" ]; then
  echo "Usage: pr-comments.sh <pr_number|pr_url> [owner/repo]"
  exit 1
fi

OWNER=""
REPO=""
NUMBER=""

# 第1引数が PR URL なら owner/repo/number を抽出
if [[ "$ARG1" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  NUMBER="${BASH_REMATCH[3]}"
else
  NUMBER="$ARG1"
fi

# 第2引数で owner/repo を明示指定（URL より優先しない: URL 指定済みなら上書き不要）
if [ -z "$OWNER" ] && [ -n "$ARG2" ]; then
  OWNER="${ARG2%%/*}"
  REPO="${ARG2##*/}"
fi

# どちらでも決まらなければカレントリポジトリにフォールバック
if [ -z "$OWNER" ]; then
  OWNER=$(gh repo view --json owner -q .owner.login)
  REPO=$(gh repo view --json name -q .name)
fi

if [ -z "$NUMBER" ]; then
  echo "PR番号を解決できませんでした" >&2
  exit 1
fi

gh api graphql \
  -f owner="$OWNER" \
  -f repo="$REPO" \
  -F number="$NUMBER" \
  -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          comments(first: 5) {
            nodes {
              body
              author { login }
              path
              line
            }
          }
        }
      }
    }
  }
}' | jq -r '
  .data.repository.pullRequest.reviewThreads.nodes
  | map(select(.isResolved == false))
  | if length == 0 then "未解決コメントなし"
    else to_entries[] | "[\(.key + 1)] \(.value.comments.nodes[0].path) (line \(.value.comments.nodes[0].line))\n@\(.value.comments.nodes[0].author.login): \(.value.comments.nodes[0].body)\n---"
    end
'

#!/usr/bin/env bash
# Usage: gh-as-owner.sh <owner/repo> -- <command...>
set -u

OWNER_REPO="${1:-}"

if [ -z "${OWNER_REPO:-}" ] || [ "${2:-}" != "--" ]; then
  echo "Usage: gh-as-owner.sh <owner/repo> -- <command...>" >&2
  exit 1
fi

shift 2

if [ "$#" -eq 0 ]; then
  echo "command が指定されていません" >&2
  exit 1
fi

OWNER="${OWNER_REPO%%/*}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
OWNER_ACCOUNT_MAP="$SKILL_DIR/owner-account-map"

TARGET_ACCOUNT=""
if [ -f "$OWNER_ACCOUNT_MAP" ]; then
  TARGET_ACCOUNT=$(awk -v owner="$OWNER" '
    NF && $1 !~ /^#/ && $1 == owner { print $2; exit }
  ' "$OWNER_ACCOUNT_MAP")
fi

if [ -n "$TARGET_ACCOUNT" ]; then
  PREV_ACCOUNT=$(gh api user --jq .login 2>/dev/null || true)
  if [ -z "$PREV_ACCOUNT" ]; then
    echo "warning: owner '$OWNER' maps to gh account '$TARGET_ACCOUNT', but current gh account could not be detected; continuing with current gh auth" >&2
  elif [ "$TARGET_ACCOUNT" != "$PREV_ACCOUNT" ]; then
    if gh auth switch --user "$TARGET_ACCOUNT" >/dev/null 2>&1; then
      trap 'gh auth switch --user "$PREV_ACCOUNT" >/dev/null 2>&1 || true' EXIT
    else
      echo "warning: owner '$OWNER' maps to gh account '$TARGET_ACCOUNT', but switching failed; continuing with current gh auth" >&2
    fi
  fi
fi

"$@"

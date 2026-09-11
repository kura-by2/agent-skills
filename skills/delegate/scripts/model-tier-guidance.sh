#!/bin/bash
# Usage: model-tier-guidance.sh [codex|claude]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/model-cache.sh"

BACKEND="${1:-}"

if [ "$#" -gt 1 ]; then
  printf 'Usage: model-tier-guidance.sh [codex|claude]\n' >&2
  exit 1
fi

case "$BACKEND" in
  "")
    BACKENDS=(codex claude)
    ;;
  codex|claude)
    BACKENDS=("$BACKEND")
    ;;
  *)
    printf 'Usage: model-tier-guidance.sh [codex|claude]\n' >&2
    exit 1
    ;;
esac

for backend in "${BACKENDS[@]}"; do
  delegate_ensure_model_cache "$backend"
done

delegate_report_model_tier_guidance "$BACKEND"

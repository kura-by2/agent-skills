#!/bin/bash

if [ -z "${AGENT_PROJECT_DIR:-}" ]; then
  echo "AGENT_PROJECT_DIR が設定されていません" >&2
  exit 1
fi

DIR="$AGENT_PROJECT_DIR/memory/contexts"

#!/bin/bash

PROJECT_DIR="${AGENT_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || true
fi
if [ -z "$PROJECT_DIR" ]; then
  echo "AGENT_PROJECT_DIR、CLAUDE_PROJECT_DIR、カレントディレクトリの git リポジトリからプロジェクトルートを解決できません" >&2
  exit 1
fi

DIR="$PROJECT_DIR/memory/contexts"

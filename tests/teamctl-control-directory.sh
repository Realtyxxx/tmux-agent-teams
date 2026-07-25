#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEAMCTL="$ROOT_DIR/skills/tmux-agent-teams/teamctl.sh"
TEST_ROOT=$(mktemp -d "/private/tmp/teamctl-control-dir.XXXXXX")
INVALID_DIR="$TEST_ROOT/not-allowed"
VALID_DIR="$TEST_ROOT/.tmux-agent-team"

cleanup() {
  if command -v trash-put >/dev/null 2>&1; then
    trash-put "$TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if TEAM_DIR="$INVALID_DIR" "$TEAMCTL" init invalid directory >/dev/null 2>&1; then
  fail "init accepted a control directory not named .tmux-agent-team"
fi

TEAM_DIR="$VALID_DIR" "$TEAMCTL" init valid directory >/dev/null

for path in \
  "$VALID_DIR/tasks" \
  "$VALID_DIR/artifacts" \
  "$VALID_DIR/receipts" \
  "$VALID_DIR/workers.tsv" \
  "$VALID_DIR/board.tsv" \
  "$VALID_DIR/worktrees.tsv" \
  "$VALID_DIR/team-meta.env"; do
  [ -e "$path" ] || fail "missing control-plane path: $path"
done

printf 'PASS: control-plane files stay under .tmux-agent-team\n'

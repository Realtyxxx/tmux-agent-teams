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
  "$VALID_DIR/agents.tsv" \
  "$VALID_DIR/workers.tsv" \
  "$VALID_DIR/board.tsv" \
  "$VALID_DIR/worktrees.tsv" \
  "$VALID_DIR/team-meta.env"; do
  [ -e "$path" ] || fail "missing control-plane path: $path"
done

printf 'alice\t%%1\n' > "$VALID_DIR/workers.tsv"
printf 'impl-1\talice\n' > "$VALID_DIR/board.tsv"
printf '# frozen mode\n' > "$VALID_DIR/mode.md"

if TEAM_DIR="$VALID_DIR" "$TEAMCTL" init reinit directory >/dev/null 2>&1; then
  fail "init reset a control directory that already has a team"
fi

[ -s "$VALID_DIR/workers.tsv" ] ||
  fail "a refused init still truncated the worker registry"
[ -s "$VALID_DIR/board.tsv" ] ||
  fail "a refused init still truncated the task board"

TEAM_DIR="$VALID_DIR" "$TEAMCTL" init reinit directory --force >/dev/null ||
  fail "init --force did not reset the control directory"

[ ! -s "$VALID_DIR/workers.tsv" ] ||
  fail "init --force kept the previous worker registry"
[ ! -e "$VALID_DIR/mode.md" ] ||
  fail "init --force kept the previous frozen mode"

UNINITIALIZED="$TEST_ROOT/elsewhere/.tmux-agent-team"
mkdir -p "$TEST_ROOT/elsewhere"

if OUTPUT=$(TEAM_DIR="$UNINITIALIZED" "$TEAMCTL" worktree-register \
  --dir "$TEST_ROOT" 2>&1); then
  fail "worktree-register accepted an uninitialized control directory"
fi

case "$OUTPUT" in
  *"is not initialized"*) ;;
  *) fail "uninitialized control directory was not reported: $OUTPUT" ;;
esac

case "$OUTPUT" in
  *"locked by another writer"*)
    fail "uninitialized control directory was misreported as a lock conflict"
    ;;
esac

case "$OUTPUT" in
  *"awk:"* | *"must not be empty"*)
    fail "control-plane failure leaked a follow-on error: $OUTPUT"
    ;;
esac

printf 'PASS: control-plane files stay under .tmux-agent-team\n'

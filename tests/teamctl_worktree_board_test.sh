#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEAMCTL="$ROOT_DIR/skills/tmux-agent-teams/teamctl.sh"
TEST_ROOT=$(mktemp -d "/private/tmp/teamctl-worktree-board.XXXXXX")
TEAM_DIR_UNDER_TEST="$TEST_ROOT/.tmux-agent-team"
REPOSITORY="$TEST_ROOT/repository"
SECOND_WORKTREE="$TEST_ROOT/second-worktree"
SESSION="teamctl-worktree-board-$$"

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  if command -v trash-put >/dev/null 2>&1; then
    trash-put "$TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

run_in_pane() {
  local pane="$1" tag="$2"
  local output="$TEST_ROOT/$tag.out"
  local result="$TEST_ROOT/$tag.rc"
  local command arg quoted
  shift 2

  printf -v command 'TEAM_DIR=%q %q' "$TEAM_DIR_UNDER_TEST" "$TEAMCTL"
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    command="$command $quoted"
  done
  printf -v quoted '%q' "$output"
  command="$command > $quoted 2>&1"
  printf -v quoted '%q' "$result"
  command="$command; printf '%s' \$? > $quoted"

  tmux send-keys -t "$pane" -l "$command"
  sleep 0.5
  tmux send-keys -t "$pane" Enter

  while [ ! -f "$result" ]; do
    sleep 0.1
  done

  RUN_OUTPUT=$(cat "$output")
  RUN_STATUS=$(cat "$result")
}

mkdir -p "$REPOSITORY"
git -C "$REPOSITORY" init -q -b feature/shared
git -C "$REPOSITORY" config user.email test@example.com
git -C "$REPOSITORY" config user.name "Teamctl Test"
printf 'shared branch\n' > "$REPOSITORY/marker.txt"
git -C "$REPOSITORY" add marker.txt
git -C "$REPOSITORY" commit -qm "test: create shared branch"
git -C "$REPOSITORY" worktree add -q --force "$SECOND_WORKTREE" feature/shared

tmux new-session -d -s "$SESSION" -c "$REPOSITORY"
ALICE_PANE=$(tmux display-message -p -t "$SESSION:0.0" '#{pane_id}')
BOB_PANE=$(tmux split-window -d -P -F '#{pane_id}' -t "$SESSION:0" \
  -c "$SECOND_WORKTREE")

TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" init worktree-board conflicts \
  >/dev/null
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-worker alice "$ALICE_PANE"
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-worker bob "$BOB_PANE"

run_in_pane "$ALICE_PANE" alice-register \
  worktree-register \
  --dir "$REPOSITORY"
[ "$RUN_STATUS" -eq 0 ] || fail "alice registration failed: $RUN_OUTPUT"

run_in_pane "$BOB_PANE" bob-register \
  worktree-register \
  --dir "$SECOND_WORKTREE"
[ "$RUN_STATUS" -ne 0 ] ||
  fail "two workers registered the same branch from one repository"

BOARD_OUTPUT=$(TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" worktree-board)
case "$BOARD_OUTPUT" in
  $'WORKER\tPANE_ID\tMR_ID\tWORKTREE_DIR\tBRANCH\tSTATUS'* ) ;;
  *) fail "worktree board header does not use the worker object name" ;;
esac
[ "$(printf '%s\n' "$BOARD_OUTPUT" | awk -F'\t' '$1 == "alice" { count++ } END { print count + 0 }')" -eq 1 ] ||
  fail "alice must have exactly one visible row"
[ "$(printf '%s\n' "$BOARD_OUTPUT" | awk -F'\t' '$1 == "bob" { count++ } END { print count + 0 }')" -eq 0 ] ||
  fail "bob must not have a conflicting row"

run_in_pane "$ALICE_PANE" alice-close worktree-update --status closed
[ "$RUN_STATUS" -eq 0 ] || fail "alice could not close its worktree"

run_in_pane "$BOB_PANE" bob-after-close \
  worktree-register \
  --dir "$SECOND_WORKTREE"
[ "$RUN_STATUS" -eq 0 ] ||
  fail "closed row did not release the branch: $RUN_OUTPUT"

printf 'PASS: board rejects active conflicts and releases closed branches\n'

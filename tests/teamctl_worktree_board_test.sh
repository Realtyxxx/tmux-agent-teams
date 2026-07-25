#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEAMCTL="$ROOT_DIR/skills/tmux-agent-teams/teamctl.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/teamctl-worktree-test.XXXXXX")
TEAM_DIR_UNDER_TEST="$TEST_ROOT/team"
REPO_ONE="$TEST_ROOT/feature-repo"
REPO_TWO="$TEST_ROOT/fix-repo"
SESSION="teamctl-board-$$"

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  if command -v trash-put >/dev/null 2>&1; then
    trash-put "$TEST_ROOT"
  else
    echo "test data retained at $TEST_ROOT (trash-put unavailable)" >&2
  fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "missing expected text: $needle"
}

mkdir -p "$REPO_ONE" "$REPO_TWO"
git -C "$REPO_ONE" init -q -b feature/board
git -C "$REPO_TWO" init -q -b fix/worker

tmux new-session -d -s "$SESSION" -c "$REPO_ONE"
PANE_ONE=$(tmux display-message -p -t "$SESSION:0.0" '#{pane_id}')
PANE_TWO=$(tmux split-window -d -P -F '#{pane_id}' -t "$SESSION:0" -c "$REPO_TWO")

TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" init board-test worktrees >/dev/null
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" worktree-register alice \
  --pane "$PANE_ONE" \
  --dir "$REPO_ONE"
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" worktree-register bob \
  --pane "$PANE_TWO" \
  --mr '!18' \
  --status review \
  --dir "$REPO_TWO"

BOARD_OUTPUT=$(TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" worktree-board)
assert_contains "$BOARD_OUTPUT" $'COLLEAGUE\tPANE_ID\tMR_ID\tWORKTREE_DIR\tBRANCH\tSTATUS'
assert_contains "$BOARD_OUTPUT" $'alice\t'"$PANE_ONE"$'\t-\t'"$REPO_ONE"$'\tfeature/board\tworking'
assert_contains "$BOARD_OUTPUT" $'bob\t'"$PANE_TWO"$'\t!18\t'"$REPO_TWO"$'\tfix/worker\treview'

TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" worktree-update alice \
  --mr '!17' \
  --status review
UPDATED_OUTPUT=$(TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" worktree-board)
assert_contains "$UPDATED_OUTPUT" $'alice\t'"$PANE_ONE"$'\t!17\t'"$REPO_ONE"$'\tfeature/board\treview'
[ "$(printf '%s\n' "$UPDATED_OUTPUT" | awk -F'\t' '$1 == "alice" { count++ } END { print count + 0 }')" -eq 1 ] ||
  fail "board must show only alice's latest snapshot"

STATUS_OUTPUT=$(TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" status)
assert_contains "$STATUS_OUTPUT" $'worktree\talice\t'"$PANE_ONE"$'\t!17\t'"$REPO_ONE"$'\tfeature/board\treview'

if TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" worktree-register charlie \
  --pane "$PANE_ONE" \
  --dir "$REPO_TWO" >/dev/null 2>&1; then
  fail "duplicate pane or worktree registration should fail"
fi

echo "PASS: worktree board registration, update, rendering, and conflict checks"

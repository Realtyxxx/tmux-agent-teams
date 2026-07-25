#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEAMCTL="$ROOT_DIR/skills/tmux-agent-teams/teamctl.sh"
TEST_ROOT=$(mktemp -d "/private/tmp/teamctl-self-register.XXXXXX")
TEAM_DIR_UNDER_TEST="$TEST_ROOT/.tmux-agent-team"
WORKTREE="$TEST_ROOT/feature-repo"
OTHER_WORKTREE="$TEST_ROOT/other-repo"
DETACHED_WORKTREE="$TEST_ROOT/detached-repo"
SESSION="teamctl-self-register-$$"

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
  local claimed_pane="" command arg quoted
  shift 2

  if [ "${1:-}" = "--claim-pane" ]; then
    claimed_pane="$2"
    shift 2
  fi

  printf -v command 'TEAM_DIR=%q' "$TEAM_DIR_UNDER_TEST"
  if [ -n "${RUN_LOCK_ATTEMPTS:-}" ]; then
    printf -v quoted '%q' "$RUN_LOCK_ATTEMPTS"
    command="$command TEAMCTL_WORKTREE_LOCK_ATTEMPTS=$quoted"
  fi
  if [ -n "$claimed_pane" ]; then
    printf -v quoted '%q' "$claimed_pane"
    command="$command TMUX_PANE=$quoted"
  fi
  printf -v quoted '%q' "$TEAMCTL"
  command="$command $quoted"
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

mkdir -p "$WORKTREE" "$OTHER_WORKTREE" "$DETACHED_WORKTREE"
git -C "$WORKTREE" init -q -b feature/self-register
git -C "$OTHER_WORKTREE" init -q -b feature/other
git -C "$DETACHED_WORKTREE" init -q -b feature/detached
git -C "$DETACHED_WORKTREE" config user.email test@example.com
git -C "$DETACHED_WORKTREE" config user.name "Teamctl Test"
printf 'detached\n' > "$DETACHED_WORKTREE/marker.txt"
git -C "$DETACHED_WORKTREE" add marker.txt
git -C "$DETACHED_WORKTREE" commit -qm "test: create detached head"
git -C "$DETACHED_WORKTREE" checkout -q --detach

tmux new-session -d -s "$SESSION" -c "$WORKTREE"
PANE=$(tmux display-message -p -t "$SESSION:0.0" '#{pane_id}')
BOB_PANE=$(tmux split-window -d -P -F '#{pane_id}' -t "$SESSION:0" \
  -c "$DETACHED_WORKTREE")

TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" init self-register worktree >/dev/null
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-worker alice "$PANE"
if TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-worker mallory "$PANE" \
  >/dev/null 2>&1; then
  fail "register-worker assigned one pane to multiple workers"
fi
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-worker bob "$BOB_PANE"

run_in_pane "$PANE" register worktree-register --dir "$WORKTREE"

[ "$RUN_STATUS" -eq 0 ] ||
  fail "worker could not self-register from its pane: $RUN_OUTPUT"

BOARD_OUTPUT=$(TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" worktree-board)
case "$BOARD_OUTPUT" in
  *$'alice\t'"$PANE"$'\t-\t'"$WORKTREE"$'\tfeature/self-register\tworking'*) ;;
  *) fail "board did not bind the current pane to alice: $BOARD_OUTPUT" ;;
esac

run_in_pane "$PANE" explicit-pane \
  worktree-register \
  --pane "$BOB_PANE" \
  --dir "$WORKTREE"

[ "$RUN_STATUS" -ne 0 ] ||
  fail "worktree-register accepted an explicit pane override"

run_in_pane "$PANE" move-row \
  worktree-update \
  --dir "$OTHER_WORKTREE"

[ "$RUN_STATUS" -ne 0 ] ||
  fail "worktree-update moved an existing row to another directory"

run_in_pane "$PANE" replace-active \
  worktree-register \
  --dir "$OTHER_WORKTREE"

[ "$RUN_STATUS" -ne 0 ] ||
  fail "worktree-register replaced an active worktree row"

run_in_pane "$PANE" invalid-status \
  worktree-update \
  --status invented

[ "$RUN_STATUS" -ne 0 ] ||
  fail "worktree-update accepted an unknown status"

run_in_pane "$PANE" review-without-mr \
  worktree-update \
  --status review

[ "$RUN_STATUS" -ne 0 ] ||
  fail "worktree-update entered review without an MR id"

run_in_pane "$PANE" invalid-mr \
  worktree-update \
  --mr abc \
  --status review

[ "$RUN_STATUS" -ne 0 ] ||
  fail "worktree-update accepted a malformed MR id"

run_in_pane "$PANE" skip-review \
  worktree-update \
  --mr '#1' \
  --status merged

[ "$RUN_STATUS" -ne 0 ] ||
  fail "worktree-update skipped directly from working to merged"

run_in_pane "$BOB_PANE" detached \
  worktree-register \
  --dir "$DETACHED_WORKTREE"

[ "$RUN_STATUS" -ne 0 ] ||
  fail "worktree-register accepted a detached HEAD"

run_in_pane "$BOB_PANE" spoof \
  --claim-pane "$PANE" \
  worktree-update \
  --status blocked

[ "$RUN_STATUS" -ne 0 ] ||
  fail "bob changed alice's row by overriding TMUX_PANE"

BOARD_OUTPUT=$(TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" worktree-board)
case "$BOARD_OUTPUT" in
  *$'alice\t'"$PANE"$'\t-\t'"$WORKTREE"$'\tfeature/self-register\tworking'*) ;;
  *) fail "alice's board row changed after pane spoof attempt: $BOARD_OUTPUT" ;;
esac

run_in_pane "$PANE" review \
  worktree-update \
  --mr '#1' \
  --status review
[ "$RUN_STATUS" -eq 0 ] || fail "working -> review failed: $RUN_OUTPUT"

run_in_pane "$PANE" merged worktree-update --status merged
[ "$RUN_STATUS" -eq 0 ] || fail "review -> merged failed: $RUN_OUTPUT"

run_in_pane "$PANE" closed worktree-update --status closed
[ "$RUN_STATUS" -eq 0 ] || fail "merged -> closed failed: $RUN_OUTPUT"

run_in_pane "$PANE" reopen worktree-update --status working
[ "$RUN_STATUS" -ne 0 ] || fail "closed worktree returned to working"

run_in_pane "$PANE" next-worktree \
  worktree-register \
  --dir "$OTHER_WORKTREE"
[ "$RUN_STATUS" -eq 0 ] ||
  fail "closed worker could not register its next worktree: $RUN_OUTPUT"

mkdir "$TEAM_DIR_UNDER_TEST/.worktrees.lock"
printf '%s\n' "$$" > "$TEAM_DIR_UNDER_TEST/.worktrees.lock/pid"
RUN_LOCK_ATTEMPTS=2 run_in_pane "$PANE" locked-update \
  worktree-update \
  --status blocked
unset RUN_LOCK_ATTEMPTS

[ "$RUN_STATUS" -ne 0 ] || fail "worktree update ignored an active writer lock"
trash-put "$TEAM_DIR_UNDER_TEST/.worktrees.lock"

mkdir "$TEAM_DIR_UNDER_TEST/.worktrees.lock"
printf '999999\n' > "$TEAM_DIR_UNDER_TEST/.worktrees.lock/pid"
run_in_pane "$PANE" stale-lock \
  worktree-update \
  --status blocked
[ "$RUN_STATUS" -eq 0 ] ||
  fail "stale worktree lock was not recovered: $RUN_OUTPUT"
[ ! -e "$TEAM_DIR_UNDER_TEST/.worktrees.lock" ] ||
  fail "stale worktree lock remained after update"

printf 'PASS: worker identity, ownership, and lifecycle are enforced\n'

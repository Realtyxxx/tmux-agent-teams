#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEAMCTL="$ROOT_DIR/skills/tmux-agent-teams/teamctl.sh"
TEST_ROOT=$(mktemp -d "/private/tmp/teamctl-team-resume.XXXXXX")
PROJECT="$TEST_ROOT/project"
WORKTREE="$TEST_ROOT/feature-worktree"
REMOVED_WORKTREE="$TEST_ROOT/feature-worktree.removed"
SURVIVING_WORKTREE="$TEST_ROOT/surviving-worktree"
TEAM_ROOT="$PROJECT/.teams"
TEAM_DIR_UNDER_TEST="$TEAM_ROOT/resume-team"
FAKE_BIN="$TEST_ROOT/bin"
LAUNCH_LOG="$TEST_ROOT/agent-launches.tsv"
SESSION="teamctl-resume-$$"
LEADER_SESSION_ID="11111111-1111-4111-8111-111111111111"
WORKER_SESSION_ID="22222222-2222-4222-8222-222222222222"
SURVIVING_SESSION_ID="33333333-3333-4333-8333-333333333333"

export LAUNCH_LOG

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

mkdir -p "$PROJECT" "$WORKTREE" "$SURVIVING_WORKTREE" "$FAKE_BIN"
git -C "$PROJECT" init -q -b main
git -C "$WORKTREE" init -q -b feature/resume
git -C "$SURVIVING_WORKTREE" init -q -b feature/surviving

cat > "$FAKE_BIN/codex" <<EOF
#!/bin/bash
printf 'codex\t%s\t%s\n' "\$PWD" "\$*" >> "$LAUNCH_LOG"
while :; do
  sleep 60
done
EOF

cat > "$FAKE_BIN/claude" <<EOF
#!/bin/bash
printf 'claude\t%s\t%s\n' "\$PWD" "\$*" >> "$LAUNCH_LOG"
while :; do
  sleep 60
done
EOF

chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/claude"
export PATH="$FAKE_BIN:$PATH"
unset TMUX TMUX_PANE

tmux new-session -d -s "$SESSION" -c "$PROJECT" "exec sleep 3600"
LEADER_PANE=$(tmux display-message -p -t "$SESSION:0.0" '#{pane_id}')
WORKER_PANE=$(tmux split-window -d -P -F '#{pane_id}' -t "$SESSION:0" \
  -c "$WORKTREE" "exec sleep 3600")
SURVIVING_PANE=$(tmux split-window -d -P -F '#{pane_id}' -t "$SESSION:0" \
  -c "$SURVIVING_WORKTREE" "exec sleep 3600")

TEAM_ROOT="$TEAM_ROOT" "$TEAMCTL" init resume-team "resume agents" >/dev/null
if TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" close >/dev/null 2>&1; then
  fail "close accepted a team before the leader recorded agent sessions"
fi
tmux has-session -t "$SESSION" 2>/dev/null ||
  fail "a rejected close killed the unrecorded team session"

TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-leader \
  lead "$LEADER_PANE" codex "$LEADER_SESSION_ID" "$PROJECT"
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-worker \
  alice "$WORKER_PANE"
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" record-agent-session \
  worker alice claude "$WORKER_SESSION_ID" "$WORKTREE"
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-worker \
  bob "$SURVIVING_PANE"
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" record-agent-session \
  worker bob codex "$SURVIVING_SESSION_ID" "$SURVIVING_WORKTREE"
printf 'bob\t%s\t-\t%s\tfeature/surviving\tworking\n' \
  "$SURVIVING_PANE" "$SURVIVING_WORKTREE" \
  > "$TEAM_DIR_UNDER_TEST/worktrees.tsv"

grep -Fqx \
  $'leader\tlead\tcodex\t'"$LEADER_SESSION_ID"$'\t'"$PROJECT"$'\t'"$LEADER_PANE"$'\tactive' \
  "$TEAM_DIR_UNDER_TEST/agents.tsv" ||
  fail "leader session was not recorded"
grep -Fqx \
  $'worker\talice\tclaude\t'"$WORKER_SESSION_ID"$'\t'"$WORKTREE"$'\t'"$WORKER_PANE"$'\tactive' \
  "$TEAM_DIR_UNDER_TEST/agents.tsv" ||
  fail "worker session was not recorded"
grep -Fqx \
  $'worker\tbob\tcodex\t'"$SURVIVING_SESSION_ID"$'\t'"$SURVIVING_WORKTREE"$'\t'"$SURVIVING_PANE"$'\tactive' \
  "$TEAM_DIR_UNDER_TEST/agents.tsv" ||
  fail "surviving worker session was not recorded"

CLOSE_OUTPUT=$(TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" close)
case "$CLOSE_OUTPUT" in
  *$'team\tresume-team\tclosed\t'"$SESSION"*) ;;
  *) fail "close did not report the closed team session: $CLOSE_OUTPUT" ;;
esac
if tmux has-session -t "$SESSION" 2>/dev/null; then
  fail "close left the tmux team session alive"
fi

mv "$WORKTREE" "$REMOVED_WORKTREE"

RESUME_OUTPUT=$(TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" resume)
case "$RESUME_OUTPUT" in
  *$'lead\tleader\tcodex\t'"$LEADER_SESSION_ID"$'\t'"$PROJECT"$'\tresumed\t'*) ;;
  *) fail "resume did not report the resumed leader: $RESUME_OUTPUT" ;;
esac
case "$RESUME_OUTPUT" in
  *$'alice\tworker\tclaude\t'"$WORKER_SESSION_ID"$'\t'"$WORKTREE"$'\tskipped\t-\tmissing-worktree'*) ;;
  *) fail "resume did not report the skipped worker: $RESUME_OUTPUT" ;;
esac
case "$RESUME_OUTPUT" in
  *$'bob\tworker\tcodex\t'"$SURVIVING_SESSION_ID"$'\t'"$SURVIVING_WORKTREE"$'\tresumed\t'*) ;;
  *) fail "resume did not report the surviving worker: $RESUME_OUTPUT" ;;
esac

tmux has-session -t "$SESSION" 2>/dev/null ||
  fail "resume did not recreate the team session"

attempt=0
while [ ! -s "$LAUNCH_LOG" ] && [ "$attempt" -lt 50 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -s "$LAUNCH_LOG" ] || fail "resumed agent did not launch"

LAUNCHES=$(cat "$LAUNCH_LOG")
case "$LAUNCHES" in
  *$'codex\t'"$PROJECT"$'\tresume '*"$LEADER_SESSION_ID"*) ;;
  *) fail "Codex session was not resumed by recorded ID: $LAUNCHES" ;;
esac
case "$LAUNCHES" in
  *$'codex\t'"$SURVIVING_WORKTREE"$'\tresume '*"$SURVIVING_SESSION_ID"*) ;;
  *) fail "surviving Worker session was not resumed: $LAUNCHES" ;;
esac
case "$LAUNCHES" in
  *$'claude\t'*) fail "missing-worktree Claude session was launched" ;;
esac

grep -q $'alice\tworker\tclaude\t.*\tskipped\t-\tmissing-worktree' \
  "$TEAM_DIR_UNDER_TEST/resume-report.tsv" ||
  fail "missing worktree was not persisted in the resume report"

NEW_SURVIVING_PANE=$(awk -F'\t' \
  '$1 == "worker" && $2 == "bob" { print $6; exit }' \
  "$TEAM_DIR_UNDER_TEST/agents.tsv")
LATEST_WORKTREE_PANE=$(awk -F'\t' \
  '$1 == "bob" { pane = $2 } END { print pane }' \
  "$TEAM_DIR_UNDER_TEST/worktrees.tsv")
[ "$LATEST_WORKTREE_PANE" = "$NEW_SURVIVING_PANE" ] ||
  fail "resume did not rebind the surviving worktree to its new pane"

STATUS_OUTPUT=$(TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" status)
case "$STATUS_OUTPUT" in
  *$'team\tresume-team\tactive\t'"$SESSION"*) ;;
  *) fail "resumed team did not return to active: $STATUS_OUTPUT" ;;
esac

TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" close >/dev/null

printf 'PASS: closed teams resume recorded sessions and report missing worktrees\n'

#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEAMCTL="$ROOT_DIR/skills/tmux-agent-teams/teamctl.sh"
TEST_ROOT=$(mktemp -d "/private/tmp/teamctl-runtime-adapters.XXXXXX")
PROJECT="$TEST_ROOT/project"
TEAM_ROOT="$PROJECT/.teams"
TEAM_DIR_UNDER_TEST="$TEAM_ROOT/runtime-team"
BLOCKED_TEAM_DIR="$TEAM_ROOT/agy-leader"
FAKE_BIN="$TEST_ROOT/bin"
LAUNCH_LOG="$TEST_ROOT/agent-launches.tsv"
SESSION="teamctl-runtime-adapters-$$"
BLOCKED_SESSION="teamctl-agy-leader-$$"
LEADER_SESSION_ID="44444444-4444-4444-8444-444444444444"
WORKER_SESSION_ID="55555555-5555-4555-8555-555555555555"

export LAUNCH_LOG

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux kill-session -t "$BLOCKED_SESSION" 2>/dev/null || true
  if command -v trash-put >/dev/null 2>&1; then
    trash-put "$TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$PROJECT" "$FAKE_BIN"
git -C "$PROJECT" init -q -b main

cat > "$FAKE_BIN/codex" <<EOF
#!/bin/bash
printf 'codex\t%s\t%s\n' "\$PWD" "\$*" >> "$LAUNCH_LOG"
while :; do
  sleep 60
done
EOF

cat > "$FAKE_BIN/agy" <<EOF
#!/bin/bash
printf 'agy\t%s\t%s\n' "\$PWD" "\$*" >> "$LAUNCH_LOG"
while :; do
  sleep 60
done
EOF

chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/agy"
export PATH="$FAKE_BIN:$PATH"
unset TMUX TMUX_PANE

RUNTIMES_OUTPUT=$("$TEAMCTL" runtimes)
for runtime_row in \
  $'claude\tyes\tuuid' \
  $'codex\tyes\tuuid' \
  $'agy\tno\tnone'; do
  case "$RUNTIMES_OUTPUT" in
    *"$runtime_row"*) ;;
    *) fail "runtime inventory is incomplete: $RUNTIMES_OUTPUT" ;;
  esac
done

tmux new-session -d -s "$SESSION" -c "$PROJECT" "exec sleep 3600"
LEADER_PANE=$(tmux display-message -p -t "$SESSION:0.0" '#{pane_id}')
ALICE_PANE=$(tmux split-window -d -P -F '#{pane_id}' -t "$SESSION:0" \
  -c "$PROJECT" "exec sleep 3600")
BOB_PANE=$(tmux split-window -d -P -F '#{pane_id}' -t "$SESSION:0" \
  -c "$PROJECT" "exec sleep 3600")

TEAM_ROOT="$TEAM_ROOT" "$TEAMCTL" init runtime-team "runtime adapters" \
  >/dev/null
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-leader \
  lead "$LEADER_PANE" codex "$LEADER_SESSION_ID" "$PROJECT"

if TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-worker \
  invalid "$ALICE_PANE" agy "$LEADER_SESSION_ID" "$PROJECT" \
  >/dev/null 2>&1; then
  fail "non-resumable runtime accepted a session UUID"
fi

TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-worker \
  alice "$ALICE_PANE" agy - "$PROJECT"
TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" register-worker \
  bob "$BOB_PANE" agy - "$PROJECT"

[ "$(awk -F'\t' '$1 == "worker" && $3 == "agy" && $4 == "-" { count++ }
  END { print count + 0 }' "$TEAM_DIR_UNDER_TEST/agents.tsv")" -eq 2 ] ||
  fail "non-resumable workers were not recorded independently"

TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" close >/dev/null

RESUME_OUTPUT=$(TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" resume)
case "$RESUME_OUTPUT" in
  *$'lead\tleader\tcodex\t'"$LEADER_SESSION_ID"$'\t'"$PROJECT"$'\tresumed\t'*) ;;
  *) fail "resumable leader was not restored: $RESUME_OUTPUT" ;;
esac
case "$RESUME_OUTPUT" in
  *$'alice\tworker\tagy\t-\t'"$PROJECT"$'\tskipped\t-\tunsupported-resume'*) ;;
  *) fail "first agy worker was not reported as non-resumable" ;;
esac
case "$RESUME_OUTPUT" in
  *$'bob\tworker\tagy\t-\t'"$PROJECT"$'\tskipped\t-\tunsupported-resume'*) ;;
  *) fail "second agy worker was not reported as non-resumable" ;;
esac

attempt=0
while [ ! -s "$LAUNCH_LOG" ] && [ "$attempt" -lt 50 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -s "$LAUNCH_LOG" ] || fail "resumed Codex leader did not launch"
if grep -q $'^agy\t' "$LAUNCH_LOG"; then
  fail "resume launched a runtime that declared resume unsupported"
fi

TEAM_DIR="$TEAM_DIR_UNDER_TEST" "$TEAMCTL" close >/dev/null

tmux new-session -d -s "$BLOCKED_SESSION" -c "$PROJECT" "exec sleep 3600"
BLOCKED_LEADER_PANE=$(
  tmux display-message -p -t "$BLOCKED_SESSION:0.0" '#{pane_id}'
)
BLOCKED_WORKER_PANE=$(
  tmux split-window -d -P -F '#{pane_id}' -t "$BLOCKED_SESSION:0" \
    -c "$PROJECT" "exec sleep 3600"
)

TEAM_ROOT="$TEAM_ROOT" "$TEAMCTL" init agy-leader "blocked runtime" >/dev/null
TEAM_DIR="$BLOCKED_TEAM_DIR" "$TEAMCTL" register-leader \
  lead "$BLOCKED_LEADER_PANE" agy - "$PROJECT"
TEAM_DIR="$BLOCKED_TEAM_DIR" "$TEAMCTL" register-worker \
  worker "$BLOCKED_WORKER_PANE" codex "$WORKER_SESSION_ID" "$PROJECT"
TEAM_DIR="$BLOCKED_TEAM_DIR" "$TEAMCTL" close >/dev/null

if BLOCKED_OUTPUT=$(
  TEAM_DIR="$BLOCKED_TEAM_DIR" "$TEAMCTL" resume 2>&1
); then
  fail "resume accepted a non-resumable leader"
fi
case "$BLOCKED_OUTPUT" in
  *"recorded leader cannot be resumed: unsupported-resume"*) ;;
  *) fail "non-resumable leader did not report its blocker: $BLOCKED_OUTPUT" ;;
esac
if tmux has-session -t "=$BLOCKED_SESSION" 2>/dev/null; then
  fail "blocked resume recreated the team session"
fi

printf 'PASS: runtime adapters isolate resumable and non-resumable CLIs\n'

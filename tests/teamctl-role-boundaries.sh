#!/bin/bash

set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEAMCTL="$ROOT_DIR/skills/tmux-agent-teams/teamctl.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/teamctl-role-boundaries.XXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
TMUX_LOG="$TEST_ROOT/tmux.log"
export TEAM_DIR="$TEST_ROOT/team"
export TMUX_LOG

mkdir -p "$FAKE_BIN"

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

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/bin/bash

printf '%s\n' "$*" >> "$TMUX_LOG"

case "${1:-}" in
  display)
    printf '%%9\n'
    ;;
  capture-pane)
    printf 'private implementation details\n'
    ;;
  list-panes)
    printf '%%9\t0\tcodex\t/tmp\n'
    ;;
  *)
    ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"
export PATH="$FAKE_BIN:$PATH"

"$TEAMCTL" init "boundary-test" "role separation" >/dev/null
"$TEAMCTL" register "worker-1" "%9"
"$TEAMCTL" dispatch "worker-1" "impl-1" "Implement the requested change."

dispatch_log=$(cat "$TMUX_LOG")
worker_skill="$ROOT_DIR/skills/tmux-agent-teams/worker/SKILL.md"

case "$dispatch_log" in
  *"Read $worker_skill completely before starting"*) ;;
  *) fail "dispatch did not require the worker skill" ;;
esac

case "$dispatch_log" in
  *"$TEAM_DIR/artifacts/impl-1.md"*"$TEAM_DIR/receipts/impl-1.md"*) ;;
  *) fail "dispatch did not separate work artifacts from control receipts" ;;
esac

mkdir -p "$TEAM_DIR/artifacts" "$TEAM_DIR/receipts"
printf 'private implementation details\nDONE impl-1\n' \
  > "$TEAM_DIR/artifacts/impl-1.md"

if "$TEAMCTL" wait 0 impl-1 >/dev/null 2>&1; then
  fail "wait treated a work artifact as a leader-readable completion receipt"
fi

cat > "$TEAM_DIR/receipts/impl-1.md" <<EOF
task_id: impl-1
worker: worker-1
status: completed
artifact: $TEAM_DIR/artifacts/impl-1.md
verdict: unverified
blocker: none
next: verify
summary: private implementation details
DONE impl-1
EOF

"$TEAMCTL" wait 0 impl-1 >/dev/null ||
  fail "wait did not accept the control-plane receipt"

receipt_output=$("$TEAMCTL" show-receipt impl-1)
status_output=$("$TEAMCTL" status)

case "$receipt_output" in
  *"private implementation details"*)
    fail "show-receipt exposed a non-schema field to the leader"
    ;;
esac

case "$status_output" in
  *"private implementation details"*)
    fail "status exposed work output to the leader"
    ;;
esac

printf 'PASS: leader and worker channels are separated\n'

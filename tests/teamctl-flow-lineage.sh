#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEAMCTL="$ROOT_DIR/skills/tmux-agent-teams/teamctl.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/teamctl-flow-lineage.XXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
TMUX_LOG="$TEST_ROOT/tmux.log"
export TEAM_DIR="$TEST_ROOT/.tmux-agent-team"
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
  *)
    ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"
export PATH="$FAKE_BIN:$PATH"

"$TEAMCTL" init "lineage-test" "flow lineage" >/dev/null
"$TEAMCTL" register "worker-a" "%9"
"$TEAMCTL" register "worker-b" "%10"

"$TEAMCTL" dispatch "worker-a" "root-task" "Implement the root task."
"$TEAMCTL" dispatch "worker-b" "verify-task" "Verify the root task." \
  --parent "root-task"

[ "$(wc -l < "$TEAM_DIR/flow.tsv" | tr -d ' ')" = "2" ] ||
  fail "dispatch did not append exactly two flow rows"

awk -F'\t' '
  NR == 1 && $1 ~ /^[0-9]+$/ && $2 == "root-task" &&
    $3 == "worker-a" && $4 == "-" && NF == 4 { root = 1 }
  NR == 2 && $1 ~ /^[0-9]+$/ && $2 == "verify-task" &&
    $3 == "worker-b" && $4 == "root-task" && NF == 4 { child = 1 }
  END { exit !(root && child) }
' "$TEAM_DIR/flow.tsv" || fail "flow.tsv lineage rows are invalid"

EXPECTED_BOARD=$(printf 'root-task\tworker-a\nverify-task\tworker-b')
[ "$(cat "$TEAM_DIR/board.tsv")" = "$EXPECTED_BOARD" ] ||
  fail "dispatch changed the two-column board.tsv format"

BOARD_LINES=$(wc -l < "$TEAM_DIR/board.tsv")
FLOW_LINES=$(wc -l < "$TEAM_DIR/flow.tsv")
if OUTPUT=$("$TEAMCTL" dispatch "worker-a" "bad-child" "Invalid parent." \
  --parent "bad/id" 2>&1); then
  fail "dispatch accepted an invalid parent task id"
fi
case "$OUTPUT" in
  *"invalid parent task id: bad/id"*) ;;
  *) fail "invalid parent task id was not reported: $OUTPUT" ;;
esac
[ "$(wc -l < "$TEAM_DIR/board.tsv")" = "$BOARD_LINES" ] ||
  fail "invalid parent dispatch changed board.tsv"
[ "$(wc -l < "$TEAM_DIR/flow.tsv")" = "$FLOW_LINES" ] ||
  fail "invalid parent dispatch changed flow.tsv"

if OUTPUT=$("$TEAMCTL" dispatch "worker-a" "typo-child" "Unknown parent." \
  --parent "root-taks" 2>&1); then
  fail "dispatch accepted a parent that was never dispatched"
fi
case "$OUTPUT" in
  *"unknown parent task id: root-taks"*) ;;
  *) fail "unknown parent task id was not reported: $OUTPUT" ;;
esac
[ "$(wc -l < "$TEAM_DIR/board.tsv")" = "$BOARD_LINES" ] ||
  fail "unknown parent dispatch changed board.tsv"
[ "$(wc -l < "$TEAM_DIR/flow.tsv")" = "$FLOW_LINES" ] ||
  fail "unknown parent dispatch changed flow.tsv"

if OUTPUT=$("$TEAMCTL" dispatch "worker-a" "self-child" "Self parent." \
  --parent "self-child" 2>&1); then
  fail "dispatch accepted a task naming itself as its parent"
fi
case "$OUTPUT" in
  *"task cannot be its own parent: self-child"*) ;;
  *) fail "self parent task id was not reported: $OUTPUT" ;;
esac
[ "$(wc -l < "$TEAM_DIR/board.tsv")" = "$BOARD_LINES" ] ||
  fail "self parent dispatch changed board.tsv"
[ "$(wc -l < "$TEAM_DIR/flow.tsv")" = "$FLOW_LINES" ] ||
  fail "self parent dispatch changed flow.tsv"

cat > "$TEAM_DIR/receipts/root-task.md" <<EOF
task_id: root-task
worker: worker-a
status: completed
artifact: $TEAM_DIR/artifacts/root-task.md
verdict: unverified
blocker: none
next: verify
DONE root-task
EOF

RECEIPT_OUTPUT=$("$TEAMCTL" show-receipt root-task)
case "$RECEIPT_OUTPUT" in
  *$'task\troot-task\tworker\tworker-a\tstatus\tcompleted'*) ;;
  *) fail "show-receipt no longer reads the existing board format" ;;
esac

[ "$("$TEAMCTL" idle)" = "worker-a" ] ||
  fail "idle no longer reads the existing board format"

printf 'PASS: dispatch records validated flow lineage without changing board readers\n'

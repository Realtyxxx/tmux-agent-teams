#!/bin/bash
# board-sandbox.sh — contract and sandbox assertions for skills/tmux-agent-teams/board.
#
# Covers:
#   1. GET /api/team against a synthetic team fixture: columns, badges,
#      lineage, attention, receipts_feed, roster.
#   2. An invalid receipt degrades to receipt:null + warnings, never leaking
#      its raw fields.
#   3. Heuristic lineage when flow.tsv is absent.
#   4. The sandbox bind plan never lists artifacts/, and under bwrap the
#      artifacts directory is genuinely unreadable (Linux only; skipped
#      elsewhere with an explicit note).

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BOARD_DIR="$ROOT_DIR/skills/tmux-agent-teams/board"
SERVE="$BOARD_DIR/serve.py"
LAUNCHER="$BOARD_DIR/run-sandboxed.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/board-sandbox.XXXXXX")
# The launcher resolves its paths with `pwd -P`; match that so the
# bind-plan assertions compare identical strings on macOS, where
# /var is a symlink to /private/var.
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
TEAMS_ROOT="$TEST_ROOT/.teams"
TEAM_DIR="$TEAMS_ROOT/demo"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

skip() {
  printf 'skip - %s\n' "$1"
}

[ -f "$SERVE" ] || fail "missing serve.py: $SERVE"
[ -f "$LAUNCHER" ] || fail "missing run-sandboxed.sh: $LAUNCHER"

# ---------------------------------------------------------------------------
# Fixture: one team exercising every column, badge, and failure mode.
#
#   T5        impl-a  completed pass                       -> done  (+rework,
#                                                             because its
#                                                             verify failed)
#   T5-verify reviewer completed fail                      -> done  (+verdict:fail)
#   T4        impl-a  blocked / next await_user            -> blocked
#   T8        impl-b  no receipt, worktree status blocked  -> blocked
#   T9        impl-a  complete sentinel, illegal status    -> blocked + warning
#   T7        (undispatched contract)                      -> todo
#   newbie    registered, never dispatched                 -> roster new:true
# ---------------------------------------------------------------------------

mkdir -p "$TEAM_DIR/tasks" "$TEAM_DIR/receipts" "$TEAM_DIR/artifacts"

cat > "$TEAM_DIR/team-meta.env" <<'EOF'
TEAM_NAME=demo
TEAM_TASK=refund-path
TEAM_STATUS=active
TEAM_TMUX_SESSION=team-demo
EOF

printf '# scenario: feature-mr\n\nrules go here\n' > "$TEAM_DIR/mode.md"

printf '%s\t%s\n' \
  impl-a '%1' \
  reviewer '%2' \
  impl-b '%3' \
  newbie '%4' > "$TEAM_DIR/workers.tsv"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  leader lead claude sess-lead "$TEST_ROOT" '%0' active \
  worker impl-a claude sess-a "$TEST_ROOT" '%1' active \
  worker reviewer codex sess-r "$TEST_ROOT" '%2' active \
  worker impl-b agy sess-b "$TEST_ROOT" '%3' active \
  worker newbie claude sess-n "$TEST_ROOT" '%4' active > "$TEAM_DIR/agents.tsv"

printf '%s\t%s\n' \
  T5 impl-a \
  T5-verify reviewer \
  T4 impl-a \
  T8 impl-b \
  T9 impl-a > "$TEAM_DIR/board.tsv"

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  impl-a '%1' - "$TEST_ROOT/wt-a" feat/refund working \
  impl-a '%1' '!41' "$TEST_ROOT/wt-a" feat/refund review \
  impl-b '%3' - "$TEST_ROOT/wt-b" feat/ledger blocked > "$TEAM_DIR/worktrees.tsv"

printf '%s\t%s\t%s\t%s\n' \
  1756366800 T5 impl-a - \
  1756366900 T5-verify reviewer T5 \
  1756366950 T4 impl-a - > "$TEAM_DIR/flow.tsv"

for id in T5 T5-verify T4 T8 T9 T7; do
  printf '# contract %s\n\nObjective: bounded outcome for %s\n' "$id" "$id" \
    > "$TEAM_DIR/tasks/$id.md"
done

write_receipt() {
  local id="$1" worker="$2" status="$3" artifact="$4" verdict="$5"
  local blocker="$6" next="$7"
  cat > "$TEAM_DIR/receipts/$id.md" <<EOF
task_id: $id
worker: $worker
status: $status
artifact: $artifact
verdict: $verdict
blocker: $blocker
next: $next
DONE $id
EOF
}

write_receipt T5 impl-a completed "$TEAM_DIR/artifacts/T5.md" pass none verify
write_receipt T5-verify reviewer completed \
  "$TEAM_DIR/artifacts/T5-verify.md" fail none rework
write_receipt T4 impl-a blocked none unverified missing_method await_user
# Illegal status: the whole receipt must degrade, and neither the status value
# nor the free-form line below it may appear in the response.
write_receipt T9 impl-a totally-bogus none unverified none none
printf 'leaked_secret_marker: hunter2\n' >> "$TEAM_DIR/receipts/T9.md"
printf 'DONE T9\n' >> "$TEAM_DIR/receipts/T9.md"

printf 'SECRET_ARTIFACT_MARKER internal findings\n' > "$TEAM_DIR/artifacts/T5.md"
printf 'SECRET_ARTIFACT_MARKER internal findings\n' > "$TEAM_DIR/artifacts/T5-verify.md"

# ---------------------------------------------------------------------------
# Start the server on an ephemeral port and capture the port it printed.
# ---------------------------------------------------------------------------

SERVER_LOG="$TEST_ROOT/server.log"
python3 "$SERVE" --teams-root "$TEAMS_ROOT" --port 0 > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 100); do
  PORT=$(sed -n 's#.*http://127\.0\.0\.1:\([0-9]*\).*#\1#p' "$SERVER_LOG" | head -n 1)
  [ -n "$PORT" ] && break
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$PORT" ] || fail "server did not report a port: $(cat "$SERVER_LOG")"

fetch() {
  python3 - "$1" <<'EOF'
import sys, urllib.request, urllib.error
try:
    with urllib.request.urlopen(sys.argv[1], timeout=10) as response:
        sys.stdout.write(response.read().decode("utf-8"))
except urllib.error.HTTPError as error:
    sys.stdout.write(error.read().decode("utf-8"))
    sys.exit(0)
EOF
}

BODY="$TEST_ROOT/team.json"
fetch "http://127.0.0.1:$PORT/api/team?team=demo" > "$BODY" ||
  fail "GET /api/team failed"

assert_json() {
  local label="$1" expression="$2"
  local result
  result=$(python3 - "$BODY" "$expression" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
tasks = {task["id"]: task for task in data["tasks"]}
roster = {row["worker"]: row for row in data["roster"]}
print("PASS" if eval(sys.argv[2]) else "FAIL")
EOF
  ) || fail "$label (expression raised)"
  [ "$result" = "PASS" ] || fail "$label"
  pass "$label"
}

# --- contract shape --------------------------------------------------------
assert_json "team header carries name/status/session" \
  "data['team']['name'] == 'demo' and data['team']['status'] == 'active' and data['team']['session'] == 'team-demo'"
assert_json "mode.md surfaces as a bounded plain string" \
  "data['team']['mode'] == 'scenario: feature-mr'"
assert_json "generated_at is an integer epoch" \
  "isinstance(data['generated_at'], int) and data['generated_at'] > 0"

# --- column mapping (plan section 3) ---------------------------------------
assert_json "completed receipt -> done" "tasks['T5']['column'] == 'done'"
assert_json "undispatched contract -> todo" \
  "tasks['T7']['column'] == 'todo' and tasks['T7']['owner'] is None"
assert_json "blocked receipt -> blocked" "tasks['T4']['column'] == 'blocked'"
assert_json "in-flight worktree blocked -> blocked" \
  "tasks['T8']['column'] == 'blocked'"
assert_json "title is the first non-empty contract line, plain text" \
  "tasks['T5']['title'] == 'contract T5'"

# --- badges (controlled vocabulary) ----------------------------------------
CONTROLLED="{'receipt:blocked','receipt:failed','worktree:blocked','verdict:fail','rework','new','heuristic-lineage'}"
assert_json "every badge is in the controlled vocabulary" \
  "all(set(task['badges']) <= $CONTROLLED for task in data['tasks'])"
assert_json "blocked receipt badge" \
  "'receipt:blocked' in tasks['T4']['badges']"
assert_json "worktree blocked badge" \
  "'worktree:blocked' in tasks['T8']['badges']"
assert_json "failed verdict badge" \
  "'verdict:fail' in tasks['T5-verify']['badges']"
assert_json "failed verify routes its predecessor to rework" \
  "'rework' in tasks['T5']['badges']"

# --- receipt whitelist -----------------------------------------------------
assert_json "valid receipt exposes exactly the whitelisted fields" \
  "set(tasks['T5']['receipt']) == {'status','verdict','blocker','next','artifact'}"
assert_json "invalid receipt degrades to null" \
  "tasks['T9']['receipt'] is None"
assert_json "invalid receipt is reported in warnings" \
  "'invalid-receipt:T9' in data['warnings']"
assert_json "invalid receipt is kept out of the feed" \
  "all(entry['task'] != 'T9' for entry in data['receipts_feed'])"
grep -q 'totally-bogus' "$BODY" && fail "illegal receipt status leaked into the response"
pass "illegal receipt status never echoed"
grep -q 'leaked_secret_marker' "$BODY" && fail "free-form receipt text leaked"
pass "free-form receipt text never echoed"
grep -q 'SECRET_ARTIFACT_MARKER' "$BODY" && fail "artifact content leaked into the response"
pass "artifact content never read"

# --- worktree / roster / attention / feed ----------------------------------
assert_json "worktree takes the latest row for the owner" \
  "tasks['T5']['worktree']['status'] == 'review' and tasks['T5']['worktree']['mr'] == '!41'"
assert_json "roster is derived from workers.tsv + agents.tsv" \
  "set(roster) >= {'impl-a','reviewer','impl-b','newbie'} and roster['reviewer']['runtime'] == 'codex'"
assert_json "never-dispatched worker is marked new" \
  "roster['newbie']['new'] is True and roster['impl-a']['new'] is False"
assert_json "attention holds blocked/failed/await_user tasks" \
  "'T4' in data['attention'] and 'T5' not in data['attention']"
assert_json "receipts_feed is mtime-descending and bounded" \
  "len(data['receipts_feed']) <= 20 and data['receipts_feed'] == sorted(data['receipts_feed'], key=lambda e: -e['mtime'])"

# --- lineage from flow.tsv -------------------------------------------------
assert_json "flow.tsv yields the parent chain" \
  "[node['task'] for node in tasks['T5-verify']['lineage']['chain']] == ['T5','T5-verify']"
assert_json "flow-sourced lineage is labelled flow" \
  "tasks['T5-verify']['lineage']['source'] == 'flow'"
assert_json "flow-sourced task carries no heuristic badge" \
  "'heuristic-lineage' not in tasks['T5-verify']['badges']"
assert_json "task missing from flow.tsv degrades to heuristic" \
  "tasks['T8']['lineage']['source'] == 'heuristic' and 'heuristic-lineage' in tasks['T8']['badges']"

# --- endpoint surface ------------------------------------------------------
TEAMS_JSON=$(fetch "http://127.0.0.1:$PORT/api/teams")
printf '%s' "$TEAMS_JSON" | grep -q '"demo"' || fail "/api/teams omitted the team"
pass "/api/teams lists the team"

python3 - "$PORT" <<'EOF' || exit 1
import sys, urllib.request, urllib.error
port = sys.argv[1]

def status(path, method="GET", data=None):
    request = urllib.request.Request(
        "http://127.0.0.1:%s%s" % (port, path), method=method, data=data)
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code

checks = [
    ("unknown path is 404", status("/nope"), 404),
    ("traversal team name is rejected", status("/api/team?team=../.."), 400),
    ("unknown team name is rejected", status("/api/team?team=ghost"), 400),
    ("write method is 405", status("/api/team", "POST", b""), 405),
    ("delete method is 405", status("/api/team", "DELETE"), 405),
]
failed = False
for label, actual, expected in checks:
    if actual == expected:
        print("ok - %s" % label)
    else:
        print("FAIL: %s (got %s, want %s)" % (label, actual, expected))
        failed = True
sys.exit(1 if failed else 0)
EOF

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# ---------------------------------------------------------------------------
# Heuristic lineage: same fixture minus flow.tsv.
# ---------------------------------------------------------------------------

mv "$TEAM_DIR/flow.tsv" "$TEST_ROOT/flow.tsv.bak"
python3 "$SERVE" --teams-root "$TEAMS_ROOT" --port 0 > "$TEST_ROOT/server2.log" 2>&1 &
SERVER_PID=$!
PORT2=""
for _ in $(seq 1 100); do
  PORT2=$(sed -n 's#.*http://127\.0\.0\.1:\([0-9]*\).*#\1#p' "$TEST_ROOT/server2.log" | head -n 1)
  [ -n "$PORT2" ] && break
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$PORT2" ] || fail "second server did not report a port"

fetch "http://127.0.0.1:$PORT2/api/team?team=demo" > "$BODY" ||
  fail "GET /api/team failed without flow.tsv"

assert_json "no flow.tsv -> heuristic lineage source" \
  "tasks['T5-verify']['lineage']['source'] == 'heuristic'"
assert_json "no flow.tsv -> heuristic-lineage badge" \
  "'heuristic-lineage' in tasks['T5-verify']['badges']"
assert_json "id-prefix heuristic still recovers the T5 chain" \
  "[node['task'] for node in tasks['T5-verify']['lineage']['chain']] == ['T5','T5-verify']"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
mv "$TEST_ROOT/flow.tsv.bak" "$TEAM_DIR/flow.tsv"

# ---------------------------------------------------------------------------
# Sandbox: the bind plan must never mention artifacts/.
# ---------------------------------------------------------------------------

PLAN=$("$LAUNCHER" --teams-root "$TEAMS_ROOT" --print-plan) ||
  fail "run-sandboxed --print-plan failed"
printf '%s\n' "$PLAN" | grep -q "$TEAM_DIR/receipts" ||
  fail "bind plan is missing receipts/"
printf '%s\n' "$PLAN" | grep -q "$TEAM_DIR/board.tsv" ||
  fail "bind plan is missing board.tsv"
if printf '%s\n' "$PLAN" | grep -q '/artifacts'; then
  fail "bind plan exposes artifacts/"
fi
pass "bind plan covers the contract files and never artifacts/"

# ---------------------------------------------------------------------------
# Sandbox: artifacts/ is genuinely unreadable inside bwrap. Linux only.
# ---------------------------------------------------------------------------

if [ "$(uname -s)" != "Linux" ]; then
  skip "bwrap artifacts/ isolation — not Linux ($(uname -s)); run this test on the Linux host to cover the bwrap branch"
elif ! command -v bwrap >/dev/null 2>&1; then
  skip "bwrap artifacts/ isolation — bwrap is not installed"
else
  python3 "$BOARD_DIR/serve.py" --help >/dev/null 2>&1 ||
    fail "serve.py --help failed"
  SANDBOX_LOG="$TEST_ROOT/sandbox.log"
  "$LAUNCHER" --teams-root "$TEAMS_ROOT" --mode bwrap --port 0 \
    > "$SANDBOX_LOG" 2>&1 &
  SERVER_PID=$!
  PORT3=""
  for _ in $(seq 1 150); do
    PORT3=$(sed -n 's#.*http://127\.0\.0\.1:\([0-9]*\).*#\1#p' "$SANDBOX_LOG" | head -n 1)
    [ -n "$PORT3" ] && break
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.1
  done
  [ -n "$PORT3" ] || fail "sandboxed server did not start: $(cat "$SANDBOX_LOG")"

  fetch "http://127.0.0.1:$PORT3/api/team?team=demo" > "$BODY" ||
    fail "GET /api/team failed inside the sandbox"
  assert_json "sandboxed board still aggregates the control plane" \
    "tasks['T5']['column'] == 'done' and tasks['T4']['column'] == 'blocked'"

  # Same namespace, same bind list: proves artifacts/ is absent rather than
  # merely unopened by serve.py.
  if bwrap --unshare-all --share-net --die-with-parent --proc /proc --dev /dev \
    --ro-bind /usr /usr \
    $( [ -d /lib ] && printf -- '--ro-bind /lib /lib' ) \
    $( [ -d /lib64 ] && printf -- '--ro-bind /lib64 /lib64' ) \
    --ro-bind "$TEAM_DIR/board.tsv" "$TEAM_DIR/board.tsv" \
    --ro-bind "$TEAM_DIR/receipts" "$TEAM_DIR/receipts" \
    /bin/sh -c "[ -e '$TEAM_DIR/artifacts' ]" 2>/dev/null; then
    fail "artifacts/ is visible inside the sandbox namespace"
  fi
  pass "artifacts/ is not visible inside the sandbox namespace"

  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
fi

# ---------------------------------------------------------------------------
# Sandbox: macOS seatbelt profile. artifacts/ must be unreadable through the
# very profile the launcher generates, not merely unopened by serve.py.
# ---------------------------------------------------------------------------

if ! command -v sandbox-exec >/dev/null 2>&1; then
  skip "sandbox-exec artifacts/ isolation — sandbox-exec is not available ($(uname -s))"
else
  PROFILE="$TEST_ROOT/board.sb"
  "$LAUNCHER" --teams-root "$TEAMS_ROOT" --print-profile > "$PROFILE" ||
    fail "run-sandboxed --print-profile failed"
  [ -s "$PROFILE" ] || fail "run-sandboxed --print-profile produced nothing"
  grep -q '^(deny default)$' "$PROFILE" ||
    fail "seatbelt profile does not deny by default"
  if grep -q '/artifacts' "$PROFILE"; then
    fail "seatbelt profile grants access to artifacts/"
  fi
  if sandbox-exec -f "$PROFILE" /bin/cat "$TEAM_DIR/artifacts/T5.md" \
    > /dev/null 2>&1; then
    fail "artifacts/ is readable under the seatbelt profile"
  fi
  pass "artifacts/ is denied by the seatbelt profile"
  sandbox-exec -f "$PROFILE" /bin/cat "$TEAM_DIR/board.tsv" > /dev/null 2>&1 ||
    fail "board.tsv is not readable under the seatbelt profile"
  pass "board.tsv stays readable under the seatbelt profile"

  SANDBOX_LOG="$TEST_ROOT/sandbox-exec.log"
  "$LAUNCHER" --teams-root "$TEAMS_ROOT" --mode sandbox-exec --port 0 \
    > "$SANDBOX_LOG" 2>&1 &
  SERVER_PID=$!
  PORT4=""
  for _ in $(seq 1 150); do
    PORT4=$(sed -n 's#.*http://127\.0\.0\.1:\([0-9]*\).*#\1#p' "$SANDBOX_LOG" | head -n 1)
    [ -n "$PORT4" ] && break
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.1
  done
  [ -n "$PORT4" ] || fail "sandbox-exec server did not start: $(cat "$SANDBOX_LOG")"
  fetch "http://127.0.0.1:$PORT4/api/team?team=demo" > "$BODY" ||
    fail "GET /api/team failed under sandbox-exec"
  assert_json "sandbox-exec board still aggregates the control plane" \
    "tasks['T5']['column'] == 'done' and tasks['T4']['column'] == 'blocked'"
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
fi

printf '\nboard-sandbox: all assertions passed\n'

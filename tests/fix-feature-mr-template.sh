#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAIN_SKILL="$ROOT_DIR/skills/tmux-agent-teams/SKILL.md"
TEAMCTL="$ROOT_DIR/skills/tmux-agent-teams/teamctl.sh"
MODE_ROOT="$ROOT_DIR/skills/tmux-agent-teams/modes"
MODE_INDEX="$MODE_ROOT/INDEX.md"
MODE_SOURCE="$MODE_ROOT/fix-feature-mr/MODE.md"
APPLY_MODE="$MODE_ROOT/apply-mode.sh"
TEST_ROOT=$(mktemp -d "/private/tmp/fix-feature-mr-template.XXXXXX")
CONTROL_DIR="$TEST_ROOT/.teams/mode-test"
INVALID_DIR="$TEST_ROOT/team"

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

[ -f "$MODE_SOURCE" ] || fail "missing fix-feature-MR mode"
[ -f "$MODE_INDEX" ] || fail "missing mode trigger index"
[ -f "$APPLY_MODE" ] || fail "missing mode application script"
[ ! -e "$ROOT_DIR/modes" ] || fail "modes must live inside the main skill"
if grep -Eq '(^|[[:space:]])tmux([[:space:]]|$)|git[[:space:]]+worktree|split-window|new-session' \
  "$APPLY_MODE"; then
  fail "apply-mode must not orchestrate panes or worktrees"
fi

grep -q 'modes/INDEX.md' "$MAIN_SKILL" ||
  fail "main skill does not load the mode trigger index"
grep -q 'modes/<mode>/MODE.md' "$MAIN_SKILL" ||
  fail "main skill does not define how to load a selected mode"
grep -q '.teams/<team-name>/mode.md' "$MAIN_SKILL" ||
  fail "main skill does not freeze the selected mode"
grep -q 'fix-feature-mr' "$MODE_INDEX" ||
  fail "mode index does not register fix-feature-mr"
grep -Eqi 'fix.*feature.*MR|MR.*fix.*feature' "$MODE_INDEX" ||
  fail "mode index does not describe the fix/feature + MR trigger"

mkdir -p "$CONTROL_DIR"
TEAM_DIR="$CONTROL_DIR" "$TEAMCTL" init mode-test fix-feature >/dev/null
TEAM_DIR="$CONTROL_DIR" bash "$APPLY_MODE" fix-feature-mr >/dev/null
GENERATED="$CONTROL_DIR/mode.md"
[ -f "$GENERATED" ] || fail "mode was not created under .teams/mode-test"
cmp -s "$MODE_SOURCE" "$GENERATED" ||
  fail "runtime mode snapshot differs from the selected source"

for pattern in \
  'Leader' \
  'Worker' \
  'worktree' \
  'branch' \
  'MR' \
  'review' \
  'merged' \
  'closed'; do
  grep -q "$pattern" "$GENERATED" ||
    fail "generated template is missing: $pattern"
done

if TEAM_DIR="$CONTROL_DIR" bash "$APPLY_MODE" fix-feature-mr \
  >/dev/null 2>&1; then
  fail "mode application overwrote an existing mode.md"
fi

if TEAM_DIR="$INVALID_DIR" bash "$APPLY_MODE" fix-feature-mr \
  >/dev/null 2>&1; then
  fail "mode application accepted a directory outside .teams/<team-name>"
fi

if grep -q 'fix-feature-mr\\|fix/feature MR template' "$MAIN_SKILL"; then
  fail "main skill embeds scenario-specific mode details"
fi

printf 'PASS: fix-feature-MR mode is discoverable inside the skill and safely instantiated\n'

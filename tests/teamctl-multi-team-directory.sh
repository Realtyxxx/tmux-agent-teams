#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEAMCTL="$ROOT_DIR/skills/tmux-agent-teams/teamctl.sh"
APPLY_MODE="$ROOT_DIR/skills/tmux-agent-teams/modes/apply-mode.sh"
TEST_ROOT=$(mktemp -d "/private/tmp/teamctl-multi-team.XXXXXX")
PROJECT="$TEST_ROOT/project"
TEAM_ROOT="$PROJECT/.teams"

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

mkdir -p "$PROJECT"
git -C "$PROJECT" init -q -b main

ALPHA_DIR=$(cd "$PROJECT" && TEAM_ROOT="$TEAM_ROOT" \
  "$TEAMCTL" init alpha "first task")
BETA_DIR=$(cd "$PROJECT" && TEAM_ROOT="$TEAM_ROOT" \
  "$TEAMCTL" init beta "second task")

[ "$ALPHA_DIR" = "$TEAM_ROOT/alpha" ] ||
  fail "alpha was not created under .teams/alpha: $ALPHA_DIR"
[ "$BETA_DIR" = "$TEAM_ROOT/beta" ] ||
  fail "beta was not created under .teams/beta: $BETA_DIR"

if TEAM_DIR="$TEAM_ROOT/mismatch" "$TEAMCTL" init other "wrong name" \
  >/dev/null 2>&1; then
  fail "init accepted a team name different from its .teams child directory"
fi

if TEAM_DIR="$TEST_ROOT/not.teams/fake" "$TEAMCTL" init fake "wrong root" \
  >/dev/null 2>&1; then
  fail "init accepted a parent merely ending in .teams"
fi

printf 'alpha marker\n' > "$ALPHA_DIR/tasks/keep.md"
if cd "$PROJECT" && TEAM_ROOT="$TEAM_ROOT" \
  "$TEAMCTL" init alpha "replacement task" >/dev/null 2>&1; then
  fail "init replaced an existing team"
fi
[ -f "$ALPHA_DIR/tasks/keep.md" ] ||
  fail "reinitializing alpha erased its state"

TEAMS_OUTPUT=$(cd "$PROJECT" && TEAM_ROOT="$TEAM_ROOT" "$TEAMCTL" teams)
case "$TEAMS_OUTPUT" in
  *$'alpha\tactive'*$'beta\tactive'*) ;;
  *) fail "teams did not list both isolated teams: $TEAMS_OUTPUT" ;;
esac

ALPHA_STATUS=$(cd "$PROJECT" && TEAM_ROOT="$TEAM_ROOT" \
  "$TEAMCTL" --team alpha status)
case "$ALPHA_STATUS" in
  *"team"$'\t'"alpha"$'\t'"active"*) ;;
  *) fail "--team alpha did not select alpha: $ALPHA_STATUS" ;;
esac

TEAM_DIR="$ALPHA_DIR" bash "$APPLY_MODE" fix-feature-mr >/dev/null ||
  fail "scenario mode did not accept .teams/alpha"
[ -f "$ALPHA_DIR/mode.md" ] ||
  fail "scenario mode was not isolated under .teams/alpha"
[ ! -e "$BETA_DIR/mode.md" ] ||
  fail "alpha's scenario mode leaked into beta"

printf 'PASS: one project keeps independent teams under .teams/<team-name>\n'

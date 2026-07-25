#!/bin/bash

set -euo pipefail

MODE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEAM_DIR="${TEAM_DIR:-$PWD/.tmux-agent-team}"
TEAM_DIR="${TEAM_DIR%/}"
MODE_NAME="${1:-}"
TARGET="$TEAM_DIR/mode.md"
LOCK="$TEAM_DIR/.mode.apply.lock"
TEMPORARY="$TEAM_DIR/.mode.md.$$"
LOCK_HELD=0

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

release_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  rmdir "$LOCK" 2>/dev/null || true
  LOCK_HELD=0
}

cleanup() {
  [ ! -f "$TEMPORARY" ] || unlink "$TEMPORARY" 2>/dev/null || true
  release_lock
}
trap cleanup EXIT INT TERM

case "$TEAM_DIR" in
  .tmux-agent-team | */.tmux-agent-team) ;;
  *) die "TEAM_DIR must be named .tmux-agent-team: $TEAM_DIR" ;;
esac

if ! [[ "$MODE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  die "invalid mode name: $MODE_NAME"
fi

SOURCE="$MODE_ROOT/$MODE_NAME/MODE.md"
[ -f "$SOURCE" ] || die "unknown mode: $MODE_NAME"

for required in workers.tsv board.tsv worktrees.tsv team-meta.env; do
  [ -e "$TEAM_DIR/$required" ] ||
    die "TEAM_DIR is not initialized: missing $required"
done

mkdir "$LOCK" 2>/dev/null ||
  die "another mode application is already in progress"
LOCK_HELD=1

[ ! -e "$TARGET" ] || die "mode already selected: $TARGET"
cp "$SOURCE" "$TEMPORARY"
mv "$TEMPORARY" "$TARGET"

release_lock
printf '%s\n' "$TARGET"

#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PACKAGER="$ROOT_DIR/scripts/package-releases.sh"
TEST_ROOT=$(mktemp -d "/private/tmp/package-runtime-profiles.XXXXXX")
TEMP_REPO="$TEST_ROOT/repository"
OUTPUT_DIR="$TEST_ROOT/release"
STANDARD_EXTRACT="$TEST_ROOT/standard"
AGY_EXTRACT="$TEST_ROOT/with-agy"

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

[ -f "$PACKAGER" ] || fail "missing tracked release packager"
[ -f "$ROOT_DIR/packaging/profiles/standard.files" ] ||
  fail "missing standard release profile"
[ -f "$ROOT_DIR/packaging/profiles/with-agy.files" ] ||
  fail "missing with-agy release profile"

mkdir -p "$TEMP_REPO" "$OUTPUT_DIR" "$STANDARD_EXTRACT" "$AGY_EXTRACT"
cp -R "$ROOT_DIR/skills" "$TEMP_REPO/"
cp -R "$ROOT_DIR/scripts" "$TEMP_REPO/"
cp -R "$ROOT_DIR/packaging" "$TEMP_REPO/"

git -C "$TEMP_REPO" init -q -b main
git -C "$TEMP_REPO" config user.email test@example.com
git -C "$TEMP_REPO" config user.name "Release Profile Test"
git -C "$TEMP_REPO" add skills scripts packaging
git -C "$TEMP_REPO" commit -qm "test: package runtime profiles"

(
  cd "$TEMP_REPO"
  bash scripts/package-releases.sh \
    --commit HEAD \
    --output "$OUTPUT_DIR" >/dev/null
)

COMMIT=$(git -C "$TEMP_REPO" rev-parse --short=12 HEAD)
STANDARD_ARCHIVE="$OUTPUT_DIR/tmux-agent-teams-standard-$COMMIT.tar.gz"
AGY_ARCHIVE="$OUTPUT_DIR/tmux-agent-teams-with-agy-$COMMIT.tar.gz"

[ -f "$STANDARD_ARCHIVE" ] || fail "standard archive was not created"
[ -f "$AGY_ARCHIVE" ] || fail "with-agy archive was not created"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 -c SHA256SUMS >/dev/null
) || fail "release checksums did not validate"

if tar -tzf "$STANDARD_ARCHIVE" | grep -Eq \
  'tmux-agent-teams/runtimes/agy/'; then
  fail "standard archive contains agy-specific files"
fi
tar -tzf "$AGY_ARCHIVE" |
  grep -qx 'tmux-agent-teams/runtimes/agy/runtime.sh' ||
  fail "with-agy archive is missing its runtime"
tar -tzf "$AGY_ARCHIVE" |
  grep -qx 'tmux-agent-teams/runtimes/agy/models.yaml' ||
  fail "with-agy archive is missing its model catalog"

tar -xzf "$STANDARD_ARCHIVE" -C "$STANDARD_EXTRACT"
tar -xzf "$AGY_ARCHIVE" -C "$AGY_EXTRACT"

if grep -RniE '(^|[^[:alnum:]_])agy([^[:alnum:]_]|$)' \
  "$STANDARD_EXTRACT/tmux-agent-teams" >/dev/null; then
  fail "standard archive contains an agy marker"
fi

STANDARD_RUNTIMES=$(
  "$STANDARD_EXTRACT/tmux-agent-teams/teamctl.sh" runtimes
)
case "$STANDARD_RUNTIMES" in
  *$'claude\tyes\tuuid'*$'codex\tyes\tuuid'*) ;;
  *) fail "standard archive does not expose Claude and Codex" ;;
esac
case "$STANDARD_RUNTIMES" in
  *$'agy\t'*) fail "standard archive exposes agy" ;;
esac

AGY_RUNTIMES=$("$AGY_EXTRACT/tmux-agent-teams/teamctl.sh" runtimes)
case "$AGY_RUNTIMES" in
  *$'agy\tno\tnone'*) ;;
  *) fail "with-agy archive does not expose agy" ;;
esac

mv "$AGY_EXTRACT/tmux-agent-teams/runtimes/agy" "$TEST_ROOT/agy-runtime"
diff -rq \
  "$STANDARD_EXTRACT/tmux-agent-teams" \
  "$AGY_EXTRACT/tmux-agent-teams" >/dev/null ||
  fail "release profiles package different common files"

printf 'PASS: one commit produces isolated standard and with-agy releases\n'

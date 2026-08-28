#!/bin/bash

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
SKILL_PATH="skills/tmux-agent-teams"
ARCHIVE_PREFIX="tmux-agent-teams/"
COMMIT="HEAD"
OUTPUT_DIR="$REPO_ROOT/release"

fail() {
  printf 'package-releases: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "usage: package-releases.sh [--commit revision] [--output directory]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --commit)
      [ "$#" -ge 2 ] || fail "missing value for --commit"
      COMMIT="$2"
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || fail "missing value for --output"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

if ! git -C "$REPO_ROOT" diff --quiet ||
  ! git -C "$REPO_ROOT" diff --cached --quiet; then
  fail "tracked changes must be committed before packaging"
fi

git -C "$REPO_ROOT" rev-parse --verify "$COMMIT^{commit}" >/dev/null ||
  fail "unknown commit: $COMMIT"

COMMIT_ID=$(git -C "$REPO_ROOT" rev-parse --short=12 "$COMMIT")
mkdir -p "$OUTPUT_DIR"

read_profile() {
  local entry
  PROFILE_FILES=()

  while IFS= read -r entry || [ -n "$entry" ]; do
    case "$entry" in
      '' | \#*) continue ;;
      /* | *..*) fail "unsafe profile entry: $entry" ;;
    esac
    PROFILE_FILES[${#PROFILE_FILES[@]}]="$entry"
  done
  [ "${#PROFILE_FILES[@]}" -gt 0 ] || fail "empty release profile"
}

package_profile() {
  local profile="$1" profile_path output

  profile_path="packaging/profiles/$profile.files"
  output="$OUTPUT_DIR/tmux-agent-teams-$profile-$COMMIT_ID.tar.gz"
  git -C "$REPO_ROOT" cat-file -e "$COMMIT:$profile_path" 2>/dev/null ||
    fail "missing profile at $COMMIT: $profile_path"
  read_profile < <(
    git -C "$REPO_ROOT" show "$COMMIT:$profile_path"
  )

  if [ ! -f "$output" ]; then
    git -C "$REPO_ROOT" archive \
      --format=tar.gz \
      --prefix="$ARCHIVE_PREFIX" \
      --output="$output" \
      "$COMMIT:$SKILL_PATH" \
      "${PROFILE_FILES[@]}"
  fi
  printf '%s\n' "$output"
}

STANDARD_ARCHIVE=$(package_profile standard)
AGY_ARCHIVE=$(package_profile with-agy)

if tar -tzf "$STANDARD_ARCHIVE" |
  grep -Eq 'tmux-agent-teams/runtimes/agy/'; then
  fail "standard archive contains agy-specific files"
fi
if tar -xOzf "$STANDARD_ARCHIVE" |
  grep -Ei '(^|[^[:alnum:]_])agy([^[:alnum:]_]|$)' >/dev/null; then
  fail "standard archive contains an agy marker"
fi

tar -tzf "$AGY_ARCHIVE" |
  grep -qx 'tmux-agent-teams/runtimes/agy/runtime.sh' ||
  fail "with-agy archive is missing its runtime"
tar -tzf "$AGY_ARCHIVE" |
  grep -qx 'tmux-agent-teams/runtimes/agy/models.yaml' ||
  fail "with-agy archive is missing its model catalog"

while IFS= read -r archive_entry; do
  case "$archive_entry" in
    */) continue ;;
  esac
  standard_hash=$(
    tar -xOzf "$STANDARD_ARCHIVE" "$archive_entry" | shasum -a 256 |
      awk '{ print $1 }'
  )
  agy_hash=$(
    tar -xOzf "$AGY_ARCHIVE" "$archive_entry" | shasum -a 256 |
      awk '{ print $1 }'
  )
  [ "$standard_hash" = "$agy_hash" ] ||
    fail "variant content differs: $archive_entry"
done < <(tar -tzf "$STANDARD_ARCHIVE")

(
  cd "$OUTPUT_DIR"
  shasum -a 256 \
    "$(basename "$STANDARD_ARCHIVE")" \
    "$(basename "$AGY_ARCHIVE")" > SHA256SUMS
)

printf 'standard\t%s\n' "$STANDARD_ARCHIVE"
printf 'with-agy\t%s\n' "$AGY_ARCHIVE"
printf 'checksums\t%s\n' "$OUTPUT_DIR/SHA256SUMS"

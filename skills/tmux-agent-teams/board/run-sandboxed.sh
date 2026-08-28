#!/bin/bash
# run-sandboxed.sh — launch board/serve.py with the narrowest filesystem view
# the host can give it.
#
# Three tiers, in order of preference:
#   1. Linux + bwrap      : --unshare-all --share-net, every control file bound
#                           read-only, nothing else visible.
#   2. macOS + sandbox-exec: read-only seatbelt profile.
#   3. neither            : prints "unsandboxed dev mode" and runs directly.
#
# The bind list is the mechanised form of the leader/worker protocol boundary:
# artifacts/ is NEVER bound. A board process that cannot open a worker's
# artifact cannot leak it, whatever the code does.
#
# Usage: run-sandboxed.sh --teams-root <dir> [--port N] [--host ADDR]
#        (the team is picked in the UI via /api/team?team=<name>)
#        run-sandboxed.sh --teams-root <dir> --print-plan     # dry run
#        run-sandboxed.sh --teams-root <dir> --print-profile  # seatbelt profile

set -uo pipefail

BOARD_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SERVE="$BOARD_DIR/serve.py"

TEAMS_ROOT=""
PORT="8737"
HOST="127.0.0.1"
FORCE_MODE=""
PRINT_PLAN=0
PRINT_PROFILE=0

die() {
  printf 'run-sandboxed: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '15,18p' "${BASH_SOURCE[0]}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --teams-root)
      [ "$#" -ge 2 ] || die "missing value for --teams-root"
      TEAMS_ROOT="$2"
      shift 2
      ;;
    --port)
      [ "$#" -ge 2 ] || die "missing value for --port"
      PORT="$2"
      shift 2
      ;;
    --host)
      [ "$#" -ge 2 ] || die "missing value for --host"
      HOST="$2"
      shift 2
      ;;
    --mode) # bwrap | sandbox-exec | dev — testing hook, skips autodetection
      [ "$#" -ge 2 ] || die "missing value for --mode"
      FORCE_MODE="$2"
      shift 2
      ;;
    --print-plan)
      PRINT_PLAN=1
      shift
      ;;
    --print-profile)
      PRINT_PROFILE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$TEAMS_ROOT" ] || die "missing --teams-root"
[ -d "$TEAMS_ROOT" ] || die "teams root is not a directory: $TEAMS_ROOT"
[ -f "$SERVE" ] || die "missing serve.py: $SERVE"

TEAMS_ROOT=$(cd "$TEAMS_ROOT" && pwd -P) || die "cannot resolve teams root"
case "${TEAMS_ROOT##*/}" in
  .teams) ;;
  *) die "teams root must be named .teams: $TEAMS_ROOT" ;;
esac

PYTHON=$(command -v python3) || die "python3 not found"
# Resolve the interpreter through symlinks so the bind targets the real binary.
PYTHON_REAL=$(readlink -f "$PYTHON" 2>/dev/null) || PYTHON_REAL="$PYTHON"
[ -n "$PYTHON_REAL" ] || PYTHON_REAL="$PYTHON"

# Files the board is allowed to see inside each team directory. This list is
# the contract from docs/plans/board-api-contract.md. artifacts/ is absent by
# design and must stay absent.
TEAM_FILES=(
  board.tsv
  worktrees.tsv
  agents.tsv
  workers.tsv
  flow.tsv
  mode.md
  team-meta.env
  team.meta
)
TEAM_DIRS=(
  receipts
  tasks
)

# ---------------------------------------------------------------------------
# Bind plan
# ---------------------------------------------------------------------------

BIND_SRC=()
BIND_DST=()

add_bind() {
  # Optional sources are skipped: bwrap fails hard on a missing --ro-bind src,
  # and flow.tsv / mode.md / team-meta.env are all legitimately absent.
  [ -e "$1" ] || return 0
  BIND_SRC+=("$1")
  BIND_DST+=("$2")
}

# The whole board/ directory: serve.py plus index.html, which is produced
# separately and may land after this script was last edited.
add_bind "$BOARD_DIR" "$BOARD_DIR"

for team_path in "$TEAMS_ROOT"/*; do
  [ -d "$team_path" ] || continue
  team_name="${team_path##*/}"
  case "$team_name" in
    .* | *[!A-Za-z0-9._-]*) continue ;;
  esac
  for entry in "${TEAM_FILES[@]}"; do
    add_bind "$team_path/$entry" "$team_path/$entry"
  done
  for entry in "${TEAM_DIRS[@]}"; do
    add_bind "$team_path/$entry" "$team_path/$entry"
  done
done

if [ "${#BIND_SRC[@]}" -eq 1 ]; then
  printf 'run-sandboxed: warning: no team control files found under %s\n' \
    "$TEAMS_ROOT" >&2
fi

if [ "$PRINT_PLAN" -eq 1 ]; then
  printf 'teams-root\t%s\n' "$TEAMS_ROOT"
  printf 'python\t%s\n' "$PYTHON_REAL"
  for i in "${!BIND_SRC[@]}"; do
    printf 'ro-bind\t%s\n' "${BIND_SRC[$i]}"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# Tier 1: bubblewrap
# ---------------------------------------------------------------------------

bwrap_works() {
  # --unshare-all needs unprivileged user namespaces. Where the kernel or a
  # hardening policy forbids them bwrap exists but every run fails, so probe
  # once instead of exec-ing into a guaranteed failure.
  command -v bwrap >/dev/null 2>&1 || return 1
  bwrap --unshare-all --share-net --ro-bind /usr /usr /usr/bin/true \
    >/dev/null 2>&1
}

run_bwrap() {
  local args=(
    --unshare-all
    --share-net
    --die-with-parent
    --new-session
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --ro-bind "$PYTHON_REAL" "$PYTHON_REAL"
  )
  local path
  # The interpreter's stdlib and shared objects. /usr covers the common
  # layouts; the *64 variants only exist on some distributions.
  for path in /usr /lib /lib64 /bin /sbin /etc/ssl "${PYTHON_REAL%/bin/*}"; do
    [ -e "$path" ] || continue
    case " ${args[*]} " in
      *" $path $path "*) continue ;;
    esac
    args+=(--ro-bind "$path" "$path")
  done
  local i
  for i in "${!BIND_SRC[@]}"; do
    args+=(--ro-bind "${BIND_SRC[$i]}" "${BIND_DST[$i]}")
  done
  # .teams/ itself must exist as a directory inside the sandbox so that
  # listdir() enumerates the bound team subdirectories. The bind of each
  # individual file already creates the parents as tmpfs entries.
  args+=(--chdir /)
  printf 'run-sandboxed: bubblewrap (artifacts/ not bound)\n' >&2
  exec bwrap "${args[@]}" \
    "$PYTHON_REAL" "$SERVE" --teams-root "$TEAMS_ROOT" \
    --host "$HOST" --port "$PORT"
}

# ---------------------------------------------------------------------------
# Tier 2: macOS sandbox-exec
# ---------------------------------------------------------------------------

emit_sandbox_profile() {
  local python_prefix
  # The interpreter's install prefix: bin/python3 -> the tree holding its
  # stdlib. Homebrew and conda interpreters live outside /usr entirely.
  python_prefix="${PYTHON_REAL%/*}"
  python_prefix="${python_prefix%/*}"

  printf '(version 1)\n'
  printf '(deny default)\n'
  # Non-filesystem operations stay open: the invariant this profile enforces
  # is which files the board can read, not what syscalls it may issue.
  printf '(allow process*)\n'
  printf '(allow sysctl*)\n'
  printf '(allow mach*)\n'
  printf '(allow signal)\n'
  printf '(allow ipc-posix*)\n'
  printf '(allow network-bind network-inbound)\n'
  # Metadata everywhere so path traversal resolves; content nowhere by
  # default. artifacts/ is therefore stat-able but never readable.
  printf '(allow file-read-metadata)\n'
  # dyld refuses to start without being able to read the root directory.
  printf '(allow file-read* (literal "/"))\n'
  printf '(allow file-read* (subpath "/usr") (subpath "/System") (subpath "/Library"))\n'
  printf '(allow file-read* (subpath "/private/var/db") (subpath "/dev"))\n'
  printf '(allow file-read* (subpath %s))\n' "$(sb_quote "$python_prefix")"
  local i
  for i in "${!BIND_SRC[@]}"; do
    if [ -d "${BIND_SRC[$i]}" ]; then
      printf '(allow file-read* (subpath %s))\n' "$(sb_quote "${BIND_SRC[$i]}")"
    else
      printf '(allow file-read* (literal %s))\n' "$(sb_quote "${BIND_SRC[$i]}")"
    fi
  done
  # Directory listing down to each team directory, without content access to
  # their other entries — artifacts/ stays unreadable.
  printf '(allow file-read* (literal %s))\n' "$(sb_quote "$TEAMS_ROOT")"
  local team_path team_name
  for team_path in "$TEAMS_ROOT"/*; do
    [ -d "$team_path" ] || continue
    team_name="${team_path##*/}"
    case "$team_name" in
      .* | *[!A-Za-z0-9._-]*) continue ;;
    esac
    printf '(allow file-read* (literal %s))\n' "$(sb_quote "$team_path")"
  done
}

run_sandbox_exec() {
  local profile
  # BSD mktemp only substitutes a trailing run of X, so no .sb suffix here;
  # sandbox-exec -f does not care about the extension.
  profile=$(mktemp "${TMPDIR:-/tmp}/board-sandbox-profile.XXXXXX") ||
    die "cannot create sandbox profile"
  trap 'rm -f "$profile"' EXIT
  emit_sandbox_profile > "$profile"

  printf 'run-sandboxed: sandbox-exec read-only profile (artifacts/ denied)\n' >&2
  exec sandbox-exec -f "$profile" \
    "$PYTHON_REAL" "$SERVE" --teams-root "$TEAMS_ROOT" \
    --host "$HOST" --port "$PORT"
}

sb_quote() {
  # Seatbelt profiles use TCL-ish double-quoted strings.
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

# ---------------------------------------------------------------------------
# Tier 3: unsandboxed
# ---------------------------------------------------------------------------

run_dev() {
  printf 'run-sandboxed: unsandboxed dev mode — no bwrap and no sandbox-exec on this host; the board process can read every file this user can, including artifacts/\n' >&2
  exec "$PYTHON_REAL" "$SERVE" --teams-root "$TEAMS_ROOT" \
    --host "$HOST" --port "$PORT"
}

if [ "$PRINT_PROFILE" -eq 1 ]; then
  emit_sandbox_profile
  exit 0
fi

case "$FORCE_MODE" in
  bwrap)
    command -v bwrap >/dev/null 2>&1 || die "bwrap not available"
    run_bwrap
    ;;
  sandbox-exec)
    command -v sandbox-exec >/dev/null 2>&1 || die "sandbox-exec not available"
    run_sandbox_exec
    ;;
  dev) run_dev ;;
  "") ;;
  *) die "unknown --mode: $FORCE_MODE" ;;
esac

if [ "$(uname -s)" = "Linux" ] && bwrap_works; then
  run_bwrap
elif command -v sandbox-exec >/dev/null 2>&1; then
  run_sandbox_exec
else
  run_dev
fi

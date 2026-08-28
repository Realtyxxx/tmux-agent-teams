#!/bin/bash
# teamctl.sh — role-separated primitives for agent CLIs in tmux panes.
# Protocol: the leader sends one literal line; workers write substantive
# artifacts separately from bounded control receipts.
set -uo pipefail

valid_team_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

TEAM_SELECTOR=""
if [ "${1:-}" = "--team" ]; then
  [ "$#" -ge 2 ] || {
    echo "missing value for --team" >&2
    exit 1
  }
  TEAM_SELECTOR="$2"
  shift 2
fi

cmd="${1:-help}"
shift || true

if [ -z "${TEAM_ROOT:-}" ]; then
  if project_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    TEAM_ROOT="$project_root/.teams"
  else
    TEAM_ROOT="$PWD/.teams"
  fi
fi
TEAM_ROOT="${TEAM_ROOT%/}"
case "$TEAM_ROOT" in
  .teams | */.teams) ;;
  *)
    echo "TEAM_ROOT must be named .teams: $TEAM_ROOT" >&2
    exit 1
    ;;
esac

if [ -n "${TEAM_DIR:-}" ]; then
  :
elif [ "$cmd" = "init" ]; then
  valid_team_name "${1:-}" || {
    echo "invalid team name: ${1:-}" >&2
    exit 1
  }
  TEAM_DIR="$TEAM_ROOT/$1"
elif [ -n "$TEAM_SELECTOR" ]; then
  valid_team_name "$TEAM_SELECTOR" || {
    echo "invalid team name: $TEAM_SELECTOR" >&2
    exit 1
  }
  TEAM_DIR="$TEAM_ROOT/$TEAM_SELECTOR"
elif [ "$cmd" = "teams" ]; then
  TEAM_DIR="$TEAM_ROOT/.unselected"
else
  # Keep explicit compatibility for control planes created before
  # project-local .teams/<team-name> directories were introduced.
  TEAM_DIR="$PWD/.tmux-agent-team"
fi

TEAM_DIR="${TEAM_DIR%/}"
team_dir_name="${TEAM_DIR##*/}"
team_dir_parent="${TEAM_DIR%/*}"
if [ "$cmd" != "teams" ]; then
  case "$TEAM_DIR:$team_dir_parent" in
    .tmux-agent-team:* | */.tmux-agent-team:*) ;;
    *)
      [ "${team_dir_parent##*/}" = ".teams" ] || {
        echo "TEAM_DIR must be .teams/<team-name>: $TEAM_DIR" >&2
        exit 1
      }
      valid_team_name "$team_dir_name" || {
        echo "invalid team directory name: $team_dir_name" >&2
        exit 1
      }
      ;;
  esac
fi
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKER_SKILL="${WORKER_SKILL:-$SCRIPT_DIR/worker/SKILL.md}"
RUNTIME_DIR="$SCRIPT_DIR/runtimes"
REG="$TEAM_DIR/workers.tsv"
AGENTS="$TEAM_DIR/agents.tsv"
BOARD="$TEAM_DIR/board.tsv"
FLOW="$TEAM_DIR/flow.tsv"
WORKTREE_BOARD="$TEAM_DIR/worktrees.tsv"
WORKTREE_LOCK="$TEAM_DIR/.worktrees.lock"
ARTIFACTS="$TEAM_DIR/artifacts"
RECEIPTS="$TEAM_DIR/receipts"
TEAM_META="$TEAM_DIR/team-meta.env"
RESUME_REPORT="$TEAM_DIR/resume-report.tsv"
WORKTREE_LOCK_HELD=0

[ -f "$TEAM_META" ] && . "$TEAM_META" 2>/dev/null
TEAM_NAME="${TEAM_NAME:-}"
TEAM_TASK="${TEAM_TASK:-}"
TEAM_STATUS="${TEAM_STATUS:-active}"
TEAM_TMUX_SESSION="${TEAM_TMUX_SESSION:-}"

_apply_window_title() {
  local title=""
  if [ -n "$TEAM_NAME" ] && [ -n "$TEAM_TASK" ]; then
    title="🤖 TEAM: $TEAM_NAME | $TEAM_TASK"
  elif [ -n "$TEAM_NAME" ]; then
    title="🤖 TEAM: $TEAM_NAME"
  elif [ -n "$TEAM_TASK" ]; then
    title="🤖 TEAM | $TEAM_TASK"
  fi
  if [ -n "$title" ] && command -v tmux >/dev/null 2>&1; then
    tmux rename-window "$title" 2>/dev/null || true
    tmux set-window-option automatic-rename off 2>/dev/null || true
  fi
}

_save_meta() {
  printf 'TEAM_NAME=%q\nTEAM_TASK=%q\nTEAM_STATUS=%q\nTEAM_TMUX_SESSION=%q\n' \
    "$TEAM_NAME" "$TEAM_TASK" "$TEAM_STATUS" "$TEAM_TMUX_SESSION" \
    > "$TEAM_META"
}

_error() {
  echo "$*" >&2
}

# Only safe in the main shell. Helpers used inside a command substitution must
# report with _error and return non-zero so the caller can exit.
_die() {
  _error "$*"
  exit 1
}

_clear_runtime() {
  unset RUNTIME_NAME RUNTIME_RESUME_SUPPORTED RUNTIME_SESSION_ID_KIND
  unset -f runtime_validate_session_id runtime_full_access_command \
    runtime_build_resume_command 2>/dev/null || true
}

_load_runtime() {
  local runtime="$1" runtime_file

  _clear_runtime
  [[ "$runtime" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
  runtime_file="$RUNTIME_DIR/$runtime/runtime.sh"
  [ -f "$runtime_file" ] || return 1
  [ -f "$RUNTIME_DIR/$runtime/instructions.md" ] || return 1
  # Runtime names are validated above, and only package-owned files below the
  # fixed runtime directory are sourced.
  . "$runtime_file" || return 1
  [ "${RUNTIME_NAME:-}" = "$runtime" ] || return 1
  case "${RUNTIME_RESUME_SUPPORTED:-}:${RUNTIME_SESSION_ID_KIND:-}" in
    yes:uuid | no:none) ;;
    *) return 1 ;;
  esac
  declare -F runtime_validate_session_id >/dev/null || return 1
  declare -F runtime_full_access_command >/dev/null || return 1
  declare -F runtime_build_resume_command >/dev/null || return 1
}

_release_worktree_lock() {
  local owner=""

  [ "$WORKTREE_LOCK_HELD" -eq 1 ] || return 0
  [ -f "$WORKTREE_LOCK/pid" ] && owner=$(cat "$WORKTREE_LOCK/pid")
  if [ "$owner" = "$$" ]; then
    unlink "$WORKTREE_LOCK/pid" 2>/dev/null || true
    rmdir "$WORKTREE_LOCK" 2>/dev/null || true
  fi
  WORKTREE_LOCK_HELD=0
}

_acquire_worktree_lock() {
  local attempts="${TEAMCTL_WORKTREE_LOCK_ATTEMPTS:-50}"
  local count=0 owner=""

  case "$attempts" in
    '' | *[!0-9]*) _die "invalid worktree lock attempts: $attempts" ;;
  esac
  [ "$attempts" -gt 0 ] ||
    _die "worktree lock attempts must be greater than zero"

  while ! mkdir "$WORKTREE_LOCK" 2>/dev/null; do
    if [ -f "$WORKTREE_LOCK/pid" ]; then
      owner=$(cat "$WORKTREE_LOCK/pid")
      if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
        unlink "$WORKTREE_LOCK/pid" 2>/dev/null || true
        rmdir "$WORKTREE_LOCK" 2>/dev/null || true
        continue
      fi
    fi
    count=$((count + 1))
    [ "$count" -lt "$attempts" ] ||
      _die "worktree board is locked by another writer"
    sleep 0.1
  done

  printf '%s\n' "$$" > "$WORKTREE_LOCK/pid"
  WORKTREE_LOCK_HELD=1
  trap '_release_worktree_lock' EXIT
  trap '_release_worktree_lock; exit 130' INT
  trap '_release_worktree_lock; exit 143' TERM
}

_validate_board_field() {
  local label="$1" value="$2"
  [ -n "$value" ] || _die "$label must not be empty"
  case "$value" in
    *$'\t'* | *$'\n'* | *$'\r'*)
      _die "$label must not contain tabs or newlines"
      ;;
  esac
}

_registered_pane() {
  local name="$1"
  [ -f "$REG" ] || return 0
  awk -F'\t' -v n="$name" '$1 == n { pane = $2 } END { print pane }' "$REG"
}

_registered_worker_for_pane() {
  local pane="$1"
  [ -f "$REG" ] || return 0
  awk -F'\t' -v p="$pane" '$2 == p { worker = $1 } END { print worker }' "$REG"
}

_register_agent_session() {
  local role="$1" name="$2" pane="$3" runtime="$4" session_id="$5"
  local requested_dir="${6:-}" pane_meta tmux_session pane_dir workdir
  local existing

  [ "$TEAM_STATUS" = "active" ] ||
    _die "cannot register an agent in a $TEAM_STATUS team: $TEAM_NAME"
  _validate_board_field "agent role" "$role"
  _validate_board_field "agent name" "$name"
  _validate_board_field "pane id" "$pane"
  _validate_board_field "agent runtime" "$runtime"
  _validate_board_field "agent session id" "$session_id"
  case "$role" in
    leader | worker) ;;
    *) _die "invalid agent role: $role" ;;
  esac
  _load_runtime "$runtime" || _die "unsupported agent runtime: $runtime"
  runtime_validate_session_id "$session_id" ||
    _die "invalid $runtime session id: $session_id"

  pane_meta=$(tmux display-message -p -t "$pane" \
    '#{session_name}	#{pane_current_path}' 2>/dev/null) ||
    _die "no such pane: $pane"
  IFS=$'\t' read -r tmux_session pane_dir <<< "$pane_meta"
  _validate_board_field "tmux session" "$tmux_session"
  [ -n "$requested_dir" ] || requested_dir="$pane_dir"
  workdir=$(cd "$requested_dir" 2>/dev/null && pwd -P) ||
    _die "agent working directory does not exist: $requested_dir"
  _validate_board_field "agent working directory" "$workdir"

  touch "$AGENTS"
  existing=$(awk -F'\t' -v n="$name" -v p="$pane" -v s="$session_id" '
    $2 == n || $6 == p || (s != "-" && $4 == s) { print $2; exit }
  ' "$AGENTS")
  [ -z "$existing" ] ||
    _die "agent name, pane, or session is already registered: $existing"
  if [ "$role" = "leader" ] &&
    awk -F'\t' '$1 == "leader" { found = 1 } END { exit !found }' "$AGENTS"; then
    _die "team already has a registered leader"
  fi

  if [ -z "$TEAM_TMUX_SESSION" ]; then
    TEAM_TMUX_SESSION="$tmux_session"
    _save_meta
  elif [ "$TEAM_TMUX_SESSION" != "$tmux_session" ]; then
    _die "agent pane belongs to another tmux session: $tmux_session"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\tactive\n' \
    "$role" "$name" "$runtime" "$session_id" "$workdir" "$pane" >> "$AGENTS"
}

# Proves the caller really runs inside the pane it claims. A matching
# controlling terminal covers typed input; process ancestry covers agent CLIs,
# whose tool calls have no terminal at all. Exporting TMUX_PANE satisfies
# neither, because a worker cannot rewrite its own process ancestry.
_pane_owns_current_process() {
  local pane="$1" pane_tty pane_pid current_tty pid parent hops=0

  pane_tty=$(tmux display-message -p -t "$pane" '#{pane_tty}' 2>/dev/null)
  current_tty=$(tty 2>/dev/null || true)
  if [ -n "$pane_tty" ] && [ "$current_tty" = "$pane_tty" ]; then
    return 0
  fi

  pane_pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
  case "$pane_pid" in
    '' | *[!0-9]*) return 1 ;;
  esac

  pid=$$
  while [ "$hops" -lt 64 ]; do
    [ "$pid" = "$pane_pid" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$parent" in
      '' | 0 | 1 | *[!0-9]*) return 1 ;;
    esac
    pid="$parent"
    hops=$((hops + 1))
  done
  return 1
}

_current_worker_name() {
  local pane="${TMUX_PANE:-}" worker count

  if [ ! -f "$REG" ]; then
    _error "team directory is not initialized: $TEAM_DIR"
    return 1
  fi
  if [ -z "$pane" ]; then
    _error "worktree updates must run inside a registered worker pane"
    return 1
  fi
  if ! tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1; then
    _error "no such pane: $pane"
    return 1
  fi
  if ! _pane_owns_current_process "$pane"; then
    _error "current process does not run inside pane: $pane"
    return 1
  fi

  worker=$(awk -F'\t' -v p="$pane" '$2 == p { print $1 }' "$REG")
  count=$(printf '%s\n' "$worker" | awk 'NF { count++ } END { print count + 0 }')
  if [ "$count" -ne 1 ]; then
    _error "current pane is not registered to exactly one worker: $pane"
    return 1
  fi
  printf '%s\n' "$worker"
}

_latest_worktree_rows() {
  [ -f "$WORKTREE_BOARD" ] || return 0
  awk -F'\t' '
    !seen[$1]++ { order[++count] = $1 }
    { latest[$1] = $0 }
    END {
      for (i = 1; i <= count; i++) {
        print latest[order[i]]
      }
    }
  ' "$WORKTREE_BOARD"
}

_latest_worktree_row() {
  local name="$1"
  [ -f "$WORKTREE_BOARD" ] || return 0
  awk -F'\t' -v n="$name" '$1 == n { row = $0 } END { print row }' \
    "$WORKTREE_BOARD"
}

_git_common_dir() {
  local worktree="$1" common

  common=$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null) ||
    return 1
  case "$common" in
    /*) (cd "$common" && pwd -P) ;;
    *) (cd "$worktree/$common" && pwd -P) ;;
  esac
}

_parse_worktree_options() {
  local mode="$1"
  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mr | --status)
        [ "$#" -ge 2 ] || _die "missing value for $1"
        case "$1" in
          --mr) WT_MR="$2" ;;
          --status) WT_STATUS="$2" ;;
        esac
        shift 2
        ;;
      --dir)
        [ "$mode" = "register" ] ||
          _die "worktree-update cannot change the registered directory"
        [ "$#" -ge 2 ] || _die "missing value for $1"
        WT_DIR="$2"
        shift 2
        ;;
      *)
        _die "unknown worktree option: $1"
        ;;
    esac
  done
}

_resolve_worktree_pane() {
  local registered

  registered=$(_registered_pane "$WT_NAME")
  if [ -z "$WT_PANE" ]; then
    WT_PANE="${TMUX_PANE:-$registered}"
  fi
  [ -n "$WT_PANE" ] ||
    _die "cannot determine pane for $WT_NAME; run inside its registered tmux pane"
  if ! tmux display-message -p -t "$WT_PANE" '#{pane_id}' >/dev/null 2>&1; then
    _die "no such pane: $WT_PANE"
  fi
}

# Reads the live checkout. Skipped when closing a row, because removing the
# worktree is the normal end of its lifecycle and a terminal row keeps the
# directory and branch already recorded at registration time.
_resolve_worktree_git() {
  local root branch

  [ -n "$WT_DIR" ] || WT_DIR="$PWD"
  if ! root=$(git -C "$WT_DIR" rev-parse --show-toplevel 2>/dev/null); then
    _die "not a git worktree: $WT_DIR"
  fi
  WT_DIR="$root"
  WT_COMMON_DIR=$(_git_common_dir "$WT_DIR") ||
    _die "cannot resolve git common directory: $WT_DIR"

  if branch=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    WT_BRANCH="$branch"
  else
    _die "worktree must have an attached branch: $WT_DIR"
  fi
}

_validate_worktree_fields() {
  local mr_pattern='^(!|#)[1-9][0-9]*$'

  _validate_board_field "worker name" "$WT_NAME"
  _validate_board_field "pane id" "$WT_PANE"
  _validate_board_field "MR id" "$WT_MR"
  _validate_board_field "worktree dir" "$WT_DIR"
  _validate_board_field "branch name" "$WT_BRANCH"
  _validate_board_field "status" "$WT_STATUS"
  if [ "$WT_MR" != "-" ] && ! [[ "$WT_MR" =~ $mr_pattern ]]; then
    _die "invalid MR id: $WT_MR"
  fi
  case "$WT_STATUS" in
    working | blocked | review | merged | closed) ;;
    *) _die "invalid worktree status: $WT_STATUS" ;;
  esac
  case "$WT_STATUS:$WT_MR" in
    review:- | merged:-)
      _die "worktree status $WT_STATUS requires an MR id"
      ;;
  esac
}

_check_worktree_conflicts() {
  local conflict existing_name existing_pane existing_mr existing_dir
  local existing_branch existing_status existing_common
  conflict=$(
    _latest_worktree_rows | awk -F'\t' \
      -v name="$WT_NAME" -v pane="$WT_PANE" -v dir="$WT_DIR" '
        $1 != name && $6 != "closed" && ($2 == pane || $4 == dir) {
          print $1
          exit
        }
      '
  )
  [ -z "$conflict" ] ||
    _die "worktree board conflict with $conflict (pane or directory already registered)"

  while IFS=$'\t' read -r existing_name existing_pane existing_mr \
    existing_dir existing_branch existing_status; do
    [ "$existing_name" != "$WT_NAME" ] || continue
    [ "$existing_status" != "closed" ] || continue
    [ "$existing_branch" = "$WT_BRANCH" ] || continue
    existing_common=$(_git_common_dir "$existing_dir" 2>/dev/null || true)
    if [ -n "$existing_common" ] && [ "$existing_common" = "$WT_COMMON_DIR" ]; then
      _die "worktree board conflict with $existing_name (branch already registered)"
    fi
  done < <(_latest_worktree_rows)
}

_validate_worktree_transition() {
  local previous="$1" next="$2"

  case "$previous:$next" in
    working:working | working:blocked | working:review | working:closed) ;;
    blocked:blocked | blocked:working | blocked:closed) ;;
    review:review | review:working | review:merged | review:closed) ;;
    merged:merged | merged:closed) ;;
    closed:closed) ;;
    *) _die "invalid worktree status transition: $previous -> $next" ;;
  esac
}

_ensure_worktree_registration_available() {
  local row previous_status

  row=$(_latest_worktree_row "$WT_NAME")
  [ -z "$row" ] && return 0

  IFS=$'\t' read -r _ _ _ _ _ previous_status <<< "$row"
  [ "$previous_status" = "closed" ] ||
    _die "worker already has an active worktree: $WT_NAME"
}

_append_worktree_snapshot() {
  mkdir -p "$TEAM_DIR"
  touch "$WORKTREE_BOARD"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$WT_NAME" "$WT_PANE" "$WT_MR" "$WT_DIR" "$WT_BRANCH" "$WT_STATUS" \
    >> "$WORKTREE_BOARD"
}

_agent_resume_workdir() {
  local role="$1" name="$2" registered_dir="$3" row

  if [ "$role" = "worker" ]; then
    row=$(_latest_worktree_row "$name")
    if [ -n "$row" ]; then
      IFS=$'\t' read -r _ _ _ registered_dir _ _ <<< "$row"
    fi
  fi
  printf '%s\n' "$registered_dir"
}

_agent_resume_command() {
  local runtime="$1" session_id="$2" workdir="$3"

  [ "${RUNTIME_NAME:-}" = "$runtime" ] || return 1
  [ "${RUNTIME_RESUME_SUPPORTED:-}" = "yes" ] || return 2
  runtime_build_resume_command "$session_id" "$workdir"
}

valid_task_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

task_done() {
  local id="$1"
  local receipt="$RECEIPTS/$id.md"

  valid_task_id "$id" &&
    [ -f "$receipt" ] &&
    [ "$(tail -n 1 "$receipt")" = "DONE $id" ]
}

receipt_value() {
  local key="$1"
  local receipt="$2"

  awk -F': ' -v key="$key" '$1 == key { print $2; exit }' "$receipt"
}

show_receipt() {
  local id="$1"
  local receipt="$RECEIPTS/$id.md"
  local receipt_id receipt_worker status artifact verdict blocker next owner

  valid_task_id "$id" || _die "invalid task id: $id"
  task_done "$id" || _die "incomplete receipt: $id"

  receipt_id=$(receipt_value task_id "$receipt")
  receipt_worker=$(receipt_value worker "$receipt")
  status=$(receipt_value status "$receipt")
  artifact=$(receipt_value artifact "$receipt")
  verdict=$(receipt_value verdict "$receipt")
  blocker=$(receipt_value blocker "$receipt")
  next=$(receipt_value next "$receipt")
  owner=$(awk -F'\t' -v id="$id" '$1 == id { print $2; exit }' "$BOARD")

  [ "$receipt_id" = "$id" ] || _die "receipt task id mismatch: $id"
  [ "$receipt_worker" = "$owner" ] || _die "receipt worker mismatch: $id"
  case "$status" in
    completed | blocked | failed) ;;
    *) _die "invalid receipt status: $id" ;;
  esac
  case "$verdict" in
    pass | fail | unverified | not_applicable) ;;
    *) _die "invalid receipt verdict: $id" ;;
  esac
  case "$next" in
    verify | rework | deliver | await_user | none) ;;
    *) _die "invalid receipt next route: $id" ;;
  esac
  if ! [[ "$blocker" =~ ^(none|[A-Za-z0-9][A-Za-z0-9._-]*)$ ]]; then
    _die "invalid receipt blocker: $id"
  fi
  case "$artifact" in
    none | "$ARTIFACTS/$id.md") ;;
    *) _die "invalid receipt artifact: $id" ;;
  esac

  printf 'task\t%s\tworker\t%s\tstatus\t%s\tverdict\t%s\tblocker\t%s\tnext\t%s\tartifact\t%s\n' \
    "$id" "${owner:-unknown}" "$status" "$verdict" "$blocker" "$next" \
    "$artifact"
}

case "$cmd" in
  runtimes)
    printf 'RUNTIME\tRESUME\tSESSION_ID\tINSTRUCTIONS\n'
    for runtime_file in "$RUNTIME_DIR"/*/runtime.sh; do
      [ -f "$runtime_file" ] || continue
      runtime_name="${runtime_file%/runtime.sh}"
      runtime_name="${runtime_name##*/}"
      _load_runtime "$runtime_name" || continue
      printf '%s\t%s\t%s\t%s\n' \
        "$RUNTIME_NAME" "$RUNTIME_RESUME_SUPPORTED" \
        "$RUNTIME_SESSION_ID_KIND" \
        "$RUNTIME_DIR/$RUNTIME_NAME/instructions.md"
    done
    ;;
  init) # init [name] [task] [--force]
    init_force=0
    init_name=""
    init_task=""
    for arg in "$@"; do
      case "$arg" in
        --force) init_force=1 ;;
        *)
          if [ -z "$init_name" ]; then
            init_name="$arg"
          elif [ -z "$init_task" ]; then
            init_task="$arg"
          else
            _die "unexpected init argument: $arg"
          fi
          ;;
        esac
    done
    if [ "${team_dir_parent##*/}" = ".teams" ] &&
      [ "$init_name" != "$team_dir_name" ]; then
      _die "team name must match its .teams directory: $team_dir_name"
    fi
    # Keyed on control-plane files, not on the directory: an operator may create
    # an empty control directory first, but an initialized team is never
    # silently replaced.
    if [ "$init_force" -eq 0 ]; then
      for existing in \
        "$TEAM_META" "$REG" "$BOARD" "$FLOW" "$WORKTREE_BOARD"; do
        [ -e "$existing" ] &&
          _die "team already exists: $TEAM_DIR (pass --force to reset)"
      done
    fi
    mkdir -p "$ARTIFACTS" "$RECEIPTS" "$TEAM_DIR/tasks"
    : > "$REG"
    : > "$AGENTS"
    : > "$BOARD"
    : > "$FLOW"
    : > "$WORKTREE_BOARD"
    # A reset team must not inherit the previous team's frozen mode.
    [ -e "$TEAM_DIR/mode.md" ] && unlink "$TEAM_DIR/mode.md"
    [ -e "$RESUME_REPORT" ] && unlink "$RESUME_REPORT"
    [ -n "$init_name" ] && TEAM_NAME="$init_name"
    [ -n "$init_task" ] && TEAM_TASK="$init_task"
    TEAM_STATUS="active"
    _save_meta
    _apply_window_title
    echo "$TEAM_DIR"
    ;;
  teams)
    printf 'TEAM\tSTATUS\tDIR\n'
    if [ -d "$TEAM_ROOT" ]; then
      for team_path in "$TEAM_ROOT"/*; do
        [ -f "$team_path/team-meta.env" ] || continue
        team_name="${team_path##*/}"
        team_status=$(awk -F= \
          '$1 == "TEAM_STATUS" { print substr($0, index($0, "=") + 1); exit }' \
          "$team_path/team-meta.env")
        printf '%s\t%s\t%s\n' \
          "$team_name" "${team_status:-unknown}" "$team_path"
      done
    fi
    ;;
  ui) # ui <session> — pane-id borders + status bar, scoped to the team session
    s="$1"
    for w in $(tmux list-windows -t "$s" -F '#{window_id}'); do
      tmux set-option -w -t "$w" pane-border-status top
      tmux set-option -w -t "$w" pane-border-format \
        ' #{?pane_active,#[reverse],}#{pane_id} #{pane_title} idx=#{pane_index} #{pane_current_command} #{pane_current_path} #[default]'
    done
    tmux set-option -t "$s" status-right-length 160
    tmux set-option -t "$s" status-right \
      'P=#{pane_id} | B=#(tmux list-buffers -F "##{buffer_name}" | head -n 1) | %H:%M'
    ;;
  layout) # layout <window> [main-width] — lead left (default 33%), seats even right
    w="$1" width="${2:-33%}"
    tmux set-window-option -t "$w" main-pane-width "$width"
    tmux select-layout -t "$w" main-vertical
    ;;
  register-leader) # register-leader <name> <pane> <runtime> <session-id> [dir]
    [ "$#" -ge 4 ] && [ "$#" -le 5 ] ||
      _die "register-leader requires name, pane, runtime, session ID, and optional directory"
    _register_agent_session leader "$@"
    tmux select-pane -t "$2" -T "$1"
    ;;
  record-agent-session) # record-agent-session <role> <name> <runtime> <id> [dir]
    [ "$#" -ge 4 ] && [ "$#" -le 5 ] ||
      _die "record-agent-session requires role, name, runtime, session ID, and optional directory"
    agent_role="$1"
    agent_name="$2"
    agent_cli="$3"
    agent_session_id="$4"
    agent_dir="${5:-}"
    case "$agent_role" in
      worker)
        agent_pane=$(_registered_pane "$agent_name")
        [ -n "$agent_pane" ] ||
          _die "worker pane is not registered: $agent_name"
        ;;
      leader)
        agent_pane="${TMUX_PANE:-}"
        [ -n "$agent_pane" ] ||
          _die "leader session recording must run inside its tmux pane"
        ;;
      *) _die "invalid agent role: $agent_role" ;;
    esac
    _register_agent_session "$agent_role" "$agent_name" "$agent_pane" \
      "$agent_cli" "$agent_session_id" "$agent_dir"
    ;;
  register | register-worker) # register-worker <name> <pane> [runtime session-id [dir]]
    _validate_board_field "worker name" "$1"
    _validate_board_field "pane id" "$2"
    [ -z "$(_registered_pane "$1")" ] ||
      _die "worker already registered: $1"
    registered_worker=$(_registered_worker_for_pane "$2")
    [ -z "$registered_worker" ] ||
      _die "pane already registered to worker: $registered_worker"
    if ! tmux display -pt "$2" '#{pane_id}' >/dev/null 2>&1; then
      echo "no such pane: $2" >&2
      exit 1
    fi
    if [ "$#" -gt 2 ]; then
      [ "$#" -ge 4 ] && [ "$#" -le 5 ] ||
        _die "register-worker session metadata requires runtime, session ID, and optional directory"
      _register_agent_session worker "$@"
    fi
    tmux select-pane -t "$2" -T "$1"
    printf '%s\t%s\n' "$1" "$2" >> "$REG"
    ;;
  close)
    [ -f "$TEAM_META" ] || _die "team is not initialized: $TEAM_DIR"
    [ "$TEAM_STATUS" = "active" ] ||
      _die "team is not active: $TEAM_NAME ($TEAM_STATUS)"
    [ -s "$AGENTS" ] ||
      _die "leader must record agent sessions before closing: $TEAM_NAME"
    leader_count=$(awk -F'\t' \
      '$1 == "leader" { count++ } END { print count + 0 }' "$AGENTS")
    [ "$leader_count" -eq 1 ] ||
      _die "team must have exactly one recorded leader: $leader_count"
    unrecorded_worker=$(awk -F'\t' '
      FNR == NR {
        if ($1 == "worker") recorded[$2] = 1
        next
      }
      !recorded[$1] { print $1; exit }
    ' "$AGENTS" "$REG")
    [ -z "$unrecorded_worker" ] ||
      _die "worker has no recorded agent session: $unrecorded_worker"

    if [ -f "$AGENTS" ]; then
      agents_closed="$TEAM_DIR/.agents.closed.$$"
      awk -F'\t' 'BEGIN { OFS = FS } { $7 = "closed"; print }' \
        "$AGENTS" > "$agents_closed"
      mv "$agents_closed" "$AGENTS"
    fi
    TEAM_STATUS="closed"
    _save_meta
    printf 'team\t%s\tclosed\t%s\n' \
      "$TEAM_NAME" "${TEAM_TMUX_SESSION:--}"

    if [ -n "$TEAM_TMUX_SESSION" ] &&
      tmux has-session -t "=$TEAM_TMUX_SESSION" 2>/dev/null; then
      tmux kill-session -t "=$TEAM_TMUX_SESSION" ||
        _die "failed to close tmux session: $TEAM_TMUX_SESSION"
    fi
    ;;
  resume)
    [ -f "$TEAM_META" ] || _die "team is not initialized: $TEAM_DIR"
    [ "$TEAM_STATUS" = "closed" ] ||
      _die "team is not closed: $TEAM_NAME ($TEAM_STATUS)"
    [ -n "$TEAM_TMUX_SESSION" ] ||
      _die "team has no recorded tmux session: $TEAM_NAME"
    [ -s "$AGENTS" ] ||
      _die "team has no recorded agent sessions: $TEAM_NAME"
    if tmux has-session -t "=$TEAM_TMUX_SESSION" 2>/dev/null; then
      _die "tmux session already exists: $TEAM_TMUX_SESSION"
    fi

    leader_count=$(awk -F'\t' \
      '$1 == "leader" { count++ } END { print count + 0 }' "$AGENTS")
    [ "$leader_count" -eq 1 ] ||
      _die "team must have exactly one recorded leader: $leader_count"

    resume_plan="$TEAM_DIR/.resume-plan.$$"
    agents_next="$TEAM_DIR/.agents.next.$$"
    workers_next="$TEAM_DIR/.workers.next.$$"
    worktrees_next="$TEAM_DIR/.worktrees.next.$$"
    report_next="$TEAM_DIR/.resume-report.next.$$"
    : > "$resume_plan"
    leader_ready=0

    while IFS=$'\t' read -r role name cli session_id registered_dir \
      old_pane old_state; do
      resume_dir=$(_agent_resume_workdir \
        "$role" "$name" "$registered_dir")
      if ! _load_runtime "$cli"; then
        printf '%s\t%s\t%s\t%s\t%s\tskipped\tmissing-runtime\t-\n' \
          "$role" "$name" "$cli" "$session_id" "$resume_dir" \
          >> "$resume_plan"
        continue
      fi
      if [ "$RUNTIME_RESUME_SUPPORTED" != "yes" ]; then
        printf '%s\t%s\t%s\t%s\t%s\tskipped\tunsupported-resume\t-\n' \
          "$role" "$name" "$cli" "$session_id" "$resume_dir" \
          >> "$resume_plan"
        continue
      fi
      if [ ! -d "$resume_dir" ]; then
        printf '%s\t%s\t%s\t%s\t%s\tskipped\tmissing-worktree\t-\n' \
          "$role" "$name" "$cli" "$session_id" "$resume_dir" \
          >> "$resume_plan"
        continue
      fi
      if ! resume_command=$(_agent_resume_command \
        "$cli" "$session_id" "$resume_dir"); then
        printf '%s\t%s\t%s\t%s\t%s\tskipped\tmissing-cli\t-\n' \
          "$role" "$name" "$cli" "$session_id" "$resume_dir" \
          >> "$resume_plan"
        continue
      fi
      [ "$role" != "leader" ] || leader_ready=1
      printf '%s\t%s\t%s\t%s\t%s\tresume\t-\t%s\n' \
        "$role" "$name" "$cli" "$session_id" "$resume_dir" \
        "$resume_command" >> "$resume_plan"
    done < <(
      awk -F'\t' '
        $1 == "leader" { leader[++leaders] = $0 }
        $1 == "worker" { worker[++workers] = $0 }
        END {
          for (i = 1; i <= leaders; i++) print leader[i]
          for (i = 1; i <= workers; i++) print worker[i]
        }
      ' "$AGENTS"
    )

    if [ "$leader_ready" -ne 1 ]; then
      leader_problem=$(awk -F'\t' '$1 == "leader" { print $7; exit }' \
        "$resume_plan")
      unlink "$resume_plan"
      _die "recorded leader cannot be resumed: ${leader_problem:-unknown}"
    fi

    : > "$agents_next"
    : > "$workers_next"
    cp "$WORKTREE_BOARD" "$worktrees_next"
    printf 'NAME\tROLE\tCLI\tSESSION_ID\tWORKDIR\tSTATUS\tPANE_ID\tDETAIL\n' \
      > "$report_next"
    session_created=0
    resumed_workers=0
    window_id=""

    while IFS=$'\t' read -r role name cli session_id resume_dir action \
      detail resume_command; do
      if [ "$action" = "skipped" ]; then
        pane="-"
        state="skipped"
      elif [ "$session_created" -eq 0 ]; then
        if ! pane=$(tmux new-session -d -P -F '#{pane_id}' \
          -s "$TEAM_TMUX_SESSION" -c "$resume_dir" "$resume_command" 2>&1); then
          for resume_temp in \
            "$resume_plan" "$agents_next" "$workers_next" "$worktrees_next" \
            "$report_next"; do
            [ ! -e "$resume_temp" ] || unlink "$resume_temp"
          done
          _die "failed to resume leader session: $pane"
        fi
        session_created=1
        window_id=$(tmux display-message -p -t "$pane" '#{window_id}')
        state="active"
      else
        if ! pane=$(tmux split-window -d -P -F '#{pane_id}' \
          -t "$window_id" -c "$resume_dir" "$resume_command" 2>&1); then
          tmux kill-session -t "=$TEAM_TMUX_SESSION" 2>/dev/null || true
          for resume_temp in \
            "$resume_plan" "$agents_next" "$workers_next" "$worktrees_next" \
            "$report_next"; do
            [ ! -e "$resume_temp" ] || unlink "$resume_temp"
          done
          _die "failed to resume agent $name: $pane"
        fi
        state="active"
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$role" "$name" "$cli" "$session_id" "$resume_dir" "$pane" "$state" \
        >> "$agents_next"
      if [ "$role" = "worker" ] && [ "$state" = "active" ]; then
        printf '%s\t%s\n' "$name" "$pane" >> "$workers_next"
        resumed_workers=$((resumed_workers + 1))
        worktree_row=$(_latest_worktree_row "$name")
        if [ -n "$worktree_row" ]; then
          IFS=$'\t' read -r _ _ worktree_mr worktree_dir worktree_branch \
            worktree_state <<< "$worktree_row"
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$pane" "$worktree_mr" "$worktree_dir" \
            "$worktree_branch" "$worktree_state" >> "$worktrees_next"
        fi
      fi
      [ "$state" != "active" ] ||
        tmux select-pane -t "$pane" -T "$name"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$role" "$cli" "$session_id" "$resume_dir" \
        "$([ "$state" = "active" ] && printf resumed || printf skipped)" \
        "$pane" "$detail" >> "$report_next"
    done < "$resume_plan"

    mv "$agents_next" "$AGENTS"
    mv "$workers_next" "$REG"
    mv "$worktrees_next" "$WORKTREE_BOARD"
    mv "$report_next" "$RESUME_REPORT"
    unlink "$resume_plan"
    TEAM_STATUS="active"
    _save_meta

    tmux set-option -w -t "$window_id" pane-border-status top \
      2>/dev/null || true
    tmux set-option -w -t "$window_id" pane-border-format \
      ' #{?pane_active,#[reverse],}#{pane_id} #{pane_title} idx=#{pane_index} #{pane_current_command} #{pane_current_path} #[default]' \
      2>/dev/null || true
    if [ "$resumed_workers" -gt 0 ]; then
      tmux set-window-option -t "$window_id" main-pane-width 33% \
        2>/dev/null || true
      tmux select-layout -t "$window_id" main-vertical 2>/dev/null || true
    fi
    cat "$RESUME_REPORT"
    ;;
  worktree-register) # worktree-register [--mr id] [--status s] [--dir path]
    WT_PANE="${TMUX_PANE:-}"
    WT_NAME=$(_current_worker_name) || exit 1
    WT_MR="-"
    WT_DIR=""
    WT_BRANCH=""
    WT_COMMON_DIR=""
    WT_STATUS="working"
    _parse_worktree_options register "$@"
    _resolve_worktree_pane
    _resolve_worktree_git
    _validate_worktree_fields
    [ "$WT_STATUS" = "working" ] ||
      _die "worktree registration must start at working: $WT_STATUS"
    _acquire_worktree_lock
    _ensure_worktree_registration_available
    _check_worktree_conflicts
    _append_worktree_snapshot
    _release_worktree_lock
    ;;
  worktree-update) # worktree-update [--mr id] [--status s]
    WT_PANE="${TMUX_PANE:-}"
    WT_NAME=$(_current_worker_name) || exit 1
    WT_COMMON_DIR=""
    _acquire_worktree_lock
    row=$(_latest_worktree_row "$WT_NAME")
    [ -n "$row" ] || _die "unregistered worktree worker: $WT_NAME"
    IFS=$'\t' read -r _ WT_PANE WT_MR WT_DIR WT_BRANCH WT_STATUS <<< "$row"
    WT_PREVIOUS_STATUS="$WT_STATUS"
    _parse_worktree_options update "$@"
    _resolve_worktree_pane
    [ "$WT_STATUS" = "closed" ] || _resolve_worktree_git
    _validate_worktree_fields
    _validate_worktree_transition "$WT_PREVIOUS_STATUS" "$WT_STATUS"
    [ "$WT_STATUS" = "closed" ] || _check_worktree_conflicts
    _append_worktree_snapshot
    _release_worktree_lock
    ;;
  worktree-board) # latest worktree snapshot for every registered worker
    printf 'WORKER\tPANE_ID\tMR_ID\tWORKTREE_DIR\tBRANCH\tSTATUS\n'
    _latest_worktree_rows
    ;;
  dispatch) # dispatch <worker> <task-id> <one-line-prompt> [--parent <id>]
    name="$1" id="$2" prompt="$3"
    shift 3
    parent="-"
    parent_set=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --parent)
          [ "$#" -ge 2 ] || _die "missing value for --parent"
          [ "$parent_set" -eq 0 ] || _die "duplicate dispatch option: --parent"
          parent="$2"
          parent_set=1
          shift 2
          ;;
        *) _die "unknown dispatch option: $1" ;;
      esac
    done
    mode_contract=""
    valid_task_id "$id" || _die "invalid task id: $id"
    if [ "$parent_set" -eq 1 ]; then
      valid_task_id "$parent" || _die "invalid parent task id: $parent"
      [ "$parent" != "$id" ] || _die "task cannot be its own parent: $id"
      # A parent must already own a board row, so lineage cannot name a task
      # that was never dispatched.
      awk -F'\t' -v p="$parent" \
        '$1 == p { found = 1; exit } END { exit !found }' \
        "$BOARD" 2>/dev/null ||
        _die "unknown parent task id: $parent"
    fi
    [ -f "$WORKER_SKILL" ] || _die "missing worker skill: $WORKER_SKILL"
    if [[ "$prompt" == *$'\n'* ]]; then
      _die "dispatch prompt must be one physical line"
    fi
    pane=$(awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$REG")
    if [ -z "$pane" ]; then
      _die "unregistered worker: $name"
    fi
    if [ -f "$TEAM_DIR/mode.md" ]; then
      mode_contract=" Read $TEAM_DIR/mode.md completely before starting and follow its additional scenario constraints."
    fi
    tmux send-keys -t "$pane" -l \
      "$prompt Read $WORKER_SKILL completely before starting and follow it as the interaction contract.$mode_contract Run every teamctl.sh command with TEAM_DIR=$TEAM_DIR prefixed, from any working directory. Write all substantive work to $ARTIFACTS/$id.md. Write only the bounded control receipt to $RECEIPTS/$id.md and make its last line exactly: DONE $id"
    sleep 0.5
    tmux send-keys -t "$pane" Enter
    printf '%s\t%s\n' "$id" "$name" >> "$BOARD"
    printf '%s\t%s\t%s\t%s\n' \
      "$(date +%s)" "$id" "$name" "$parent" >> "$FLOW"
    ;;
  wait) # wait <timeout-s> <task-id>... — receipts only
    end=$((SECONDS + $1))
    shift
    for id in "$@"; do
      until task_done "$id"; do
        if [ "$SECONDS" -ge "$end" ]; then
          echo "TIMEOUT waiting for $id" >&2
          exit 124
        fi
        sleep 2
      done
    done
    echo OK
    ;;
  show-receipt)
    show_receipt "$1"
    ;;
  idle) # registered workers with no in-flight task
    while IFS=$'\t' read -r name pane; do
      busy=0
      while IFS=$'\t' read -r id owner; do
        if [ "$owner" = "$name" ] && ! task_done "$id"; then
          busy=1
        fi
      done < "$BOARD"
      if [ "$busy" -eq 0 ]; then
        echo "$name"
      fi
    done < "$REG"
    ;;
  status) # liveness metadata + control boards; never pane text or artifacts
    printf 'team\t%s\t%s\t%s\n' \
      "${TEAM_NAME:-$team_dir_name}" "$TEAM_STATUS" "${TEAM_TMUX_SESSION:--}"
    while IFS=$'\t' read -r name pane; do
      live=$(tmux display-message -p -t "$pane" \
        '#{?pane_dead,dead,alive}:#{pane_current_command}' 2>/dev/null)
      printf 'worker\t%s\t%s\t%s\n' "$name" "$pane" "${live:-gone}"
    done < "$REG"
    while IFS=$'\t' read -r id owner; do
      if task_done "$id"; then s=done; else s=running; fi
      printf 'task\t%s\t%s\t%s\n' "$id" "$owner" "$s"
    done < "$BOARD"
    while IFS=$'\t' read -r name pane mr dir branch state; do
      printf 'worktree\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$pane" "$mr" "$dir" "$branch" "$state"
    done < <(_latest_worktree_rows)
    ;;
  set-title)
    [ -n "${1:-}" ] && TEAM_NAME="$1"
    [ -n "${2:-}" ] && TEAM_TASK="$2"
    _save_meta
    _apply_window_title
    ;;
  *)
    printf '%s\n' \
      "usage: teamctl.sh [--team name] runtimes | init <name> [task] [--force] | teams | ui <session> | layout <window> [main-width] | register-leader <name> <pane> <runtime> <session-id> [dir] | register-worker <name> <pane> [<runtime> <session-id> [dir]] | record-agent-session <role> <name> <runtime> <session-id> [dir] | close | resume | worktree-register [--mr id] [--status status] [--dir path] | worktree-update [--mr id] [--status status] | worktree-board | dispatch <worker> <id> '<prompt>' [--parent <id>] | wait <timeout> <id>... | show-receipt <id> | idle | status | set-title [name] [task]" \
      >&2
    exit 1
    ;;
esac

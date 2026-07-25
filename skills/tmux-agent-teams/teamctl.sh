#!/bin/bash
# teamctl.sh — role-separated primitives for agent CLIs in tmux panes.
# Protocol: the leader sends one literal line; workers write substantive
# artifacts separately from bounded control receipts.
set -uo pipefail
TEAM_DIR="${TEAM_DIR:-$PWD/.tmux-agent-team}"
TEAM_DIR="${TEAM_DIR%/}"
case "$TEAM_DIR" in
  .tmux-agent-team | */.tmux-agent-team) ;;
  *)
    echo "TEAM_DIR must be named .tmux-agent-team: $TEAM_DIR" >&2
    exit 1
    ;;
esac
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKER_SKILL="${WORKER_SKILL:-$SCRIPT_DIR/worker/SKILL.md}"
REG="$TEAM_DIR/workers.tsv"
BOARD="$TEAM_DIR/board.tsv"
WORKTREE_BOARD="$TEAM_DIR/worktrees.tsv"
WORKTREE_LOCK="$TEAM_DIR/.worktrees.lock"
ARTIFACTS="$TEAM_DIR/artifacts"
RECEIPTS="$TEAM_DIR/receipts"
TEAM_META="$TEAM_DIR/team-meta.env"
WORKTREE_LOCK_HELD=0

[ -f "$TEAM_META" ] && . "$TEAM_META" 2>/dev/null
TEAM_NAME="${TEAM_NAME:-}"
TEAM_TASK="${TEAM_TASK:-}"

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
  printf 'TEAM_NAME=%q\nTEAM_TASK=%q\n' "$TEAM_NAME" "$TEAM_TASK" > "$TEAM_META"
}

_die() {
  echo "$*" >&2
  exit 1
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

_current_worker_name() {
  local pane="${TMUX_PANE:-}" pane_tty current_tty worker count

  [ -n "$pane" ] ||
    _die "worktree updates must run inside a registered worker pane"
  if ! tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1; then
    _die "no such pane: $pane"
  fi
  pane_tty=$(tmux display-message -p -t "$pane" '#{pane_tty}')
  current_tty=$(tty 2>/dev/null || true)
  [ -n "$current_tty" ] && [ "$current_tty" = "$pane_tty" ] ||
    _die "current terminal does not match pane: $pane"

  worker=$(awk -F'\t' -v p="$pane" '$2 == p { print $1 }' "$REG")
  count=$(printf '%s\n' "$worker" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] ||
    _die "current pane is not registered to exactly one worker: $pane"
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

_resolve_worktree_state() {
  local registered root branch
  local mr_pattern='^(!|#)[1-9][0-9]*$'

  registered=$(_registered_pane "$WT_NAME")
  if [ -z "$WT_PANE" ]; then
    WT_PANE="${TMUX_PANE:-$registered}"
  fi
  [ -n "$WT_PANE" ] ||
    _die "cannot determine pane for $WT_NAME; run inside its registered tmux pane"
  if ! tmux display-message -p -t "$WT_PANE" '#{pane_id}' >/dev/null 2>&1; then
    _die "no such pane: $WT_PANE"
  fi

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

cmd="${1:-help}"
shift || true
case "$cmd" in
  init)
    mkdir -p "$ARTIFACTS" "$RECEIPTS" "$TEAM_DIR/tasks"
    : > "$REG"
    : > "$BOARD"
    : > "$WORKTREE_BOARD"
    [ -n "${1:-}" ] && TEAM_NAME="$1"
    [ -n "${2:-}" ] && TEAM_TASK="$2"
    _save_meta
    _apply_window_title
    echo "$TEAM_DIR"
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
  register | register-worker) # register-worker <name> <pane-id>
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
    tmux select-pane -t "$2" -T "$1"
    printf '%s\t%s\n' "$1" "$2" >> "$REG"
    ;;
  worktree-register) # worktree-register [--mr id] [--status s] [--dir path]
    WT_PANE="${TMUX_PANE:-}"
    WT_NAME=$(_current_worker_name)
    WT_MR="-"
    WT_DIR=""
    WT_BRANCH=""
    WT_STATUS="working"
    _parse_worktree_options register "$@"
    _resolve_worktree_state
    _acquire_worktree_lock
    _ensure_worktree_registration_available
    _check_worktree_conflicts
    _append_worktree_snapshot
    _release_worktree_lock
    ;;
  worktree-update) # worktree-update [--mr id] [--status s]
    WT_PANE="${TMUX_PANE:-}"
    WT_NAME=$(_current_worker_name)
    _acquire_worktree_lock
    row=$(_latest_worktree_row "$WT_NAME")
    [ -n "$row" ] || _die "unregistered worktree worker: $WT_NAME"
    IFS=$'\t' read -r _ WT_PANE WT_MR WT_DIR WT_BRANCH WT_STATUS <<< "$row"
    WT_PREVIOUS_STATUS="$WT_STATUS"
    _parse_worktree_options update "$@"
    _resolve_worktree_state
    _validate_worktree_transition "$WT_PREVIOUS_STATUS" "$WT_STATUS"
    _check_worktree_conflicts
    _append_worktree_snapshot
    _release_worktree_lock
    ;;
  worktree-board) # latest worktree snapshot for every registered worker
    printf 'WORKER\tPANE_ID\tMR_ID\tWORKTREE_DIR\tBRANCH\tSTATUS\n'
    _latest_worktree_rows
    ;;
  dispatch) # dispatch <worker> <task-id> <one-line-prompt>
    name="$1" id="$2" prompt="$3"
    mode_contract=""
    valid_task_id "$id" || _die "invalid task id: $id"
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
      "$prompt Read $WORKER_SKILL completely before starting and follow it as the interaction contract.$mode_contract Write all substantive work to $ARTIFACTS/$id.md. Write only the bounded control receipt to $RECEIPTS/$id.md and make its last line exactly: DONE $id"
    sleep 0.5
    tmux send-keys -t "$pane" Enter
    printf '%s\t%s\n' "$id" "$name" >> "$BOARD"
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
    echo "usage: teamctl.sh init [name] [task] | ui <session> | layout <window> [main-width] | register-worker <name> <pane> | worktree-register [--mr id] [--status status] [--dir path] | worktree-update [--mr id] [--status status] | worktree-board | dispatch <worker> <id> '<prompt>' | wait <timeout> <id>... | show-receipt <id> | idle | status | set-title [name] [task]" >&2
    exit 1
    ;;
esac

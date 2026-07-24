#!/bin/bash
# teamctl.sh — primitives for driving agent CLIs that live in tmux panes.
# Protocol: dispatch = ONE literal line via send-keys -l; results = mailbox
# files written by the agent (screen scraping is liveness/debug only).
# TEAM_DIR (default /tmp/agent-team) holds: panes.tsv registry, board.tsv,
# tasks/ (long context to reference in prompts), results/<id>.md mailboxes.
set -uo pipefail
TEAM_DIR="${TEAM_DIR:-/tmp/agent-team}"
REG="$TEAM_DIR/panes.tsv"
BOARD="$TEAM_DIR/board.tsv"
RES="$TEAM_DIR/results"
TEAM_META="$TEAM_DIR/team-meta.env"

[ -f "$TEAM_META" ] && . "$TEAM_META" 2>/dev/null
TEAM_NAME="${TEAM_NAME:-}"
TEAM_TASK="${TEAM_TASK:-}"

# Set the current tmux window title from TEAM_NAME and TEAM_TASK.
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

# Persist team metadata for later invocations.
_save_meta() {
  printf 'TEAM_NAME=%q\nTEAM_TASK=%q\n' "$TEAM_NAME" "$TEAM_TASK" > "$TEAM_META"
}

task_done() { [ -f "$RES/$1.md" ] && tail -1 "$RES/$1.md" | grep -q "DONE $1"; }

cmd="${1:-help}"
shift || true
case "$cmd" in
  init) # init [team-name] [task-description]
    mkdir -p "$RES" "$TEAM_DIR/tasks"
    : > "$REG"
    : > "$BOARD"
    [ -n "${1:-}" ] && TEAM_NAME="$1"
    [ -n "${2:-}" ] && TEAM_TASK="$2"
    _save_meta
    _apply_window_title
    echo "$TEAM_DIR"
    ;;
  register) # register <name> <pane-id>
    if ! tmux display -pt "$2" '#{pane_id}' >/dev/null 2>&1; then
      echo "no such pane: $2" >&2
      exit 1
    fi
    tmux select-pane -t "$2" -T "$1"
    printf '%s\t%s\n' "$1" "$2" >> "$REG"
    ;;
  dispatch) # dispatch <name> <task-id> <one-line-prompt>
    name="$1" id="$2" prompt="$3"
    pane=$(awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$REG")
    if [ -z "$pane" ]; then
      echo "unregistered agent: $name" >&2
      exit 1
    fi
    tmux send-keys -t "$pane" -l \
      "$prompt When done, write your full result to $RES/$id.md and make its last line exactly: DONE $id"
    sleep 0.5
    tmux send-keys -t "$pane" Enter
    printf '%s\t%s\n' "$id" "$name" >> "$BOARD"
    ;;
  wait) # wait <timeout-s> <task-id>...
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
  idle) # registered agents with no in-flight task
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
  status) # task board + last visible line of each pane
    while IFS=$'\t' read -r name pane; do
      last=$(tmux capture-pane -pt "$pane" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1)
      printf 'pane\t%s\t%s\t%s\n' "$name" "$pane" "${last:-<gone>}"
    done < "$REG"
    while IFS=$'\t' read -r id owner; do
      if task_done "$id"; then s=done; else s=running; fi
      printf 'task\t%s\t%s\t%s\n' "$id" "$owner" "$s"
    done < "$BOARD"
    ;;
  set-title) # set-title [team-name] [task-description]
    [ -n "${1:-}" ] && TEAM_NAME="$1"
    [ -n "${2:-}" ] && TEAM_TASK="$2"
    _save_meta
    _apply_window_title
    ;;
  *)
    echo "usage: teamctl.sh init [name] [task] | register <name> <pane> | dispatch <name> <id> '<prompt>' | wait <timeout> <id>... | idle | status | set-title [name] [task]" >&2
    exit 1
    ;;
esac

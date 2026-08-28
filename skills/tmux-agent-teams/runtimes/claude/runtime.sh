#!/bin/bash

RUNTIME_NAME="claude"
RUNTIME_RESUME_SUPPORTED="yes"
RUNTIME_SESSION_ID_KIND="uuid"

runtime_validate_session_id() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

runtime_full_access_command() {
  printf '%s\n' "command claude --dangerously-skip-permissions --model opus"
}

runtime_build_resume_command() {
  local session_id="$1" executable command

  executable=$(command -v claude) || return 1
  printf -v command '%q --resume %q' "$executable" "$session_id"
  printf '%s\n' "$command"
}

#!/bin/bash

RUNTIME_NAME="agy"
RUNTIME_RESUME_SUPPORTED="no"
RUNTIME_SESSION_ID_KIND="none"

runtime_validate_session_id() {
  [ "$1" = "-" ]
}

runtime_full_access_command() {
  printf '%s\n' "command agy --dangerously-skip-permissions"
}

runtime_build_resume_command() {
  return 2
}

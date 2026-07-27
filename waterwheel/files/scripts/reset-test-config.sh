#!/usr/bin/env bash
# Location: /usr/local/bin/reset-test-config
# Description: Deletes test task files and/or instruction files for a clean slate.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
CONFIG_HELPERS_PATH="${CONFIG_HELPERS_PATH:-/config-helpers}"
DO_TASKS=false
DO_INSTRUCTIONS=false

usage() {
  cat <<EOF
Usage: reset-test-config [-ap <agent-path>] [-cp <config-helpers-path>] [-t] [-i] [help|h|--help|-h]

Options:
  -ap <path>   Override agent path (default: /agent)
  -cp <path>   Override config helpers path (default: /config-helpers)
  -t           Delete all .md files under \$AGENT_PATH/tasks
  -i           Delete all files under \$AGENT_PATH/instructions except email-permissions.yaml
  -h, --help   Show this help message
  h, help      Show this help message

Behavior:
  When neither -t nor -i is provided, both operations are performed.
  Resetting instructions also clears the extra-instructions entries (for
  example host-testing) from the agent config status file, since the
  extra-instructions.md file that backs them is deleted.

Examples:
  reset-test-config               # reset both tasks and instructions
  reset-test-config -t            # reset tasks only
  reset-test-config -i            # reset instructions only
  reset-test-config -t -i         # same as no flags; reset both
  reset-test-config -ap /tmp/my-agent -t
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap)
      AGENT_PATH="${2:? -ap requires a value}"
      shift 2
      ;;
    -cp|--config-helpers-path)
      CONFIG_HELPERS_PATH="${2:? -cp requires a value}"
      shift 2
      ;;
    -t|--tasks|t|tasks)
      DO_TASKS=true
      shift
      ;;
    -i|--instructions|i|instructions)
      DO_INSTRUCTIONS=true
      shift
      ;;
    -h|--help|h|help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Default: perform both when neither flag is given
if [[ "$DO_TASKS" == false && "$DO_INSTRUCTIONS" == false ]]; then
  DO_TASKS=true
  DO_INSTRUCTIONS=true
fi

TASKS_DIR="${AGENT_PATH}/tasks"
INSTRUCTIONS_DIR="${AGENT_PATH}/instructions"
STATUS_FILE="${CONFIG_HELPERS_PATH}/agent-config-status.yaml"

reset_tasks() {
  if [[ ! -d "$TASKS_DIR" ]]; then
    echo "Tasks directory not found: $TASKS_DIR"
    return 0
  fi

  local count=0
  while IFS= read -r -d '' f; do
    rm -f "$f"
    count=$((count + 1))
  done < <(find "$TASKS_DIR" -maxdepth 1 -type f -name "*.md" -print0)

  if [[ $count -eq 0 ]]; then
    echo "No markdown task files found in $TASKS_DIR."
  else
    echo "Deleted $count markdown task file(s) from $TASKS_DIR."
  fi
}

reset_instructions() {
  if [[ ! -d "$INSTRUCTIONS_DIR" ]]; then
    echo "Instructions directory not found: $INSTRUCTIONS_DIR"
    return 0
  fi

  local count=0
  while IFS= read -r -d '' f; do
    rm -f "$f"
    count=$((count + 1))
  done < <(find "$INSTRUCTIONS_DIR" -maxdepth 1 -type f \
             ! -name "email-permissions.yaml" -print0)

  if [[ $count -eq 0 ]]; then
    echo "No files to delete in $INSTRUCTIONS_DIR (email-permissions.yaml is preserved)."
  else
    echo "Deleted $count file(s) from $INSTRUCTIONS_DIR (email-permissions.yaml preserved)."
  fi
}

# Resetting instructions deletes extra-instructions.md, which backs the entire
# extra-instructions array (host-testing, gemma, ...) in the status file. Strip
# that array so the status file does not advertise stale enabled features.
# Other keys (provider-mode) are preserved because their backing files live
# outside the instructions directory.
clear_extra_instructions_status() {
  if [[ ! -f "$STATUS_FILE" ]]; then
    return 0
  fi

  if ! grep -qE "^extra-instructions:[[:space:]]*$" "$STATUS_FILE"; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  awk '
    /^extra-instructions:[[:space:]]*$/ { in_block=1; next }
    in_block && /^[[:space:]]+-[[:space:]]/ { next }
    { in_block=0; print }
  ' "$STATUS_FILE" > "$tmp"
  mv "$tmp" "$STATUS_FILE"

  # Drop the status file entirely if nothing meaningful remains.
  if ! grep -qE "[^[:space:]]" "$STATUS_FILE"; then
    rm -f "$STATUS_FILE"
  fi

  echo "Cleared extra-instructions status entries from $STATUS_FILE."
}

if [[ "$DO_TASKS" == true ]]; then
  reset_tasks
fi

if [[ "$DO_INSTRUCTIONS" == true ]]; then
  reset_instructions
  clear_extra_instructions_status
fi


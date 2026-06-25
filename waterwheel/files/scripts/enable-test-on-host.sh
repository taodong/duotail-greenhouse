#!/usr/bin/env bash
# Location: /usr/local/bin/enable-test-on-host
# Description: Non-interactively enables host testing (same as config-agent's
#              enable_host_testing) and rewrites localhost -> host.docker.internal
#              in global-context.json.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
CONFIG_HELPERS_PATH="/config-helpers"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-ap <agent-path>] [-cp <config-helpers-path>] [help|h|--help|-h]

Enables host testing for the agent. This mirrors the "Enable host testing"
action in config-agent (enable_host_testing):
  - Appends the host-testing block from extra-local.md to extra-instructions.md
  - Records the host-testing entry in the agent config status file
  - Rewrites localhost -> host.docker.internal in allowed-domains.yaml

In addition, if \$AGENT_PATH/instructions/global-context.json exists, every
'localhost' value in it is rewritten to 'host.docker.internal'.

Options:
  -ap, --agent-path <path>            Override agent path (default: /agent)
  -cp, --config-helpers-path <path>   Override config helpers path (default: /config-helpers)
  -h, --help, h, help                 Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap|--agent-path)
      AGENT_PATH="${2:?--agent-path requires a value}"
      shift 2
      ;;
    -cp|--config-helpers-path)
      CONFIG_HELPERS_PATH="${2:?--config-helpers-path requires a value}"
      shift 2
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

ALLOWED_DOMAINS_FILE="${AGENT_PATH}/instructions/allowed-domains.yaml"
EXTRA_INSTRUCTION_FILE="${AGENT_PATH}/instructions/extra-instructions.md"
GLOBAL_CONTEXT_FILE="${AGENT_PATH}/instructions/global-context.json"
EXTRA_LOCAL_FILE="${CONFIG_HELPERS_PATH}/extra-local.md"
STATUS_FILE="${CONFIG_HELPERS_PATH}/agent-config-status.yaml"

HOST_TESTING_START="<!-- host-testing-start -->"
HOST_TESTING_END="<!-- host-testing-end -->"

is_host_testing_enabled() {
  [[ -f "$STATUS_FILE" ]] && grep -qF "  - host-testing" "$STATUS_FILE"
}

# Add an entry to the extra-instructions array in the status file.
status_add_entry() {
  local entry="$1"
  if [[ ! -f "$STATUS_FILE" ]]; then
    printf "extra-instructions:\n  - %s\n" "$entry" > "$STATUS_FILE"
  elif ! grep -qF "  - ${entry}" "$STATUS_FILE"; then
    if ! grep -qE "^extra-instructions:" "$STATUS_FILE"; then
      echo "extra-instructions:" >> "$STATUS_FILE"
    fi
    echo "  - ${entry}" >> "$STATUS_FILE"
  fi
}

enable_host_testing() {
  if is_host_testing_enabled; then
    echo "  Host testing is already enabled."
    return 0
  fi

  if [[ ! -f "$EXTRA_LOCAL_FILE" ]]; then
    echo "  Error: $EXTRA_LOCAL_FILE not found." >&2
    return 1
  fi

  if [[ ! -f "$EXTRA_INSTRUCTION_FILE" ]]; then
    local dir
    dir="$(dirname "$EXTRA_INSTRUCTION_FILE")"
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
    fi
    printf "# Extra Test Instruction\n\n## Global Rules\n" > "$EXTRA_INSTRUCTION_FILE"
  fi

  {
    printf "\n%s\n" "$HOST_TESTING_START"
    cat "$EXTRA_LOCAL_FILE"
    printf "\n%s\n" "$HOST_TESTING_END"
  } >> "$EXTRA_INSTRUCTION_FILE"

  status_add_entry "host-testing"

  if [[ -f "$ALLOWED_DOMAINS_FILE" ]] && grep -q "localhost" "$ALLOWED_DOMAINS_FILE"; then
    local tmp
    tmp="$(mktemp)"
    sed 's/localhost/host.docker.internal/g' "$ALLOWED_DOMAINS_FILE" > "$tmp"
    mv "$tmp" "$ALLOWED_DOMAINS_FILE"
    echo "  Updated allowed-domains.yaml: localhost -> host.docker.internal"
  fi

  echo "  Host testing enabled."
}

rewrite_global_context() {
  if [[ -f "$GLOBAL_CONTEXT_FILE" ]] && grep -q "localhost" "$GLOBAL_CONTEXT_FILE"; then
    local tmp
    tmp="$(mktemp)"
    sed 's/localhost/host.docker.internal/g' "$GLOBAL_CONTEXT_FILE" > "$tmp"
    mv "$tmp" "$GLOBAL_CONTEXT_FILE"
    echo "  Updated global-context.json: localhost -> host.docker.internal"
  fi
}

enable_host_testing
rewrite_global_context

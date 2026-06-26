#!/usr/bin/env bash
# Location: /usr/local/bin/output-context-variables
# Description: Outputs user-scoped context values from the latest run as a flat JSON object.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: output-context-variables [-ap <agent-path>]

Outputs the user-scoped context values from the latest run as a flat JSON
object, read from <agent-path>/outputs/test-context.json.

Options:
   -ap <agent-path>          Override the agent path (default: \$AGENT_PATH or /agent)
   -h, --help, h, help       Show this help message
EOF
}

case "${1:-}" in
    -h | --help | h | help)
        usage
        exit 0
        ;;
esac

if [[ "${1:-}" == "-ap" ]]; then
    if [ -z "${2:-}" ]; then
        echo "ERROR: -ap requires an agent path." >&2
        exit 1
    fi
    AGENT_PATH="$2"
    shift 2
fi

# shellcheck source=run-qa-lib.sh
# Support both development (.sh) and container (no extension) installs.
_LIB="${SCRIPT_DIR}/run-qa-lib"
# shellcheck disable=SC1090
source "${_LIB}.sh" 2>/dev/null || source "${_LIB}"

CONTEXT_FILE="${AGENT_PATH}/outputs/test-context.json"

if is_run_qa_active; then
    echo "ERROR: Testing is in progress (run-qa pid: $RUN_QA_ACTIVE_PID). Exporting context variables while testing is in progress isn't supported." >&2
    exit 1
fi

if [ ! -f "$CONTEXT_FILE" ]; then
    echo "ERROR: No test-context.json found at $CONTEXT_FILE." >&2
    exit 1
fi

# Keep only elements whose scope is "user" and that carry both a key and a value.
# Strip the "user." prefix from the key and emit a flat { key: value } object.
# An empty result (no user-scoped elements) yields {}.
jq '
    [ (if type == "object" then .[] else empty end)
      | select(type == "object" and .scope == "user" and has("key") and has("value"))
      | { key: (.key | ltrimstr("user.")), value: .value }
    ] | from_entries
' "$CONTEXT_FILE"

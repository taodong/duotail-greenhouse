#!/usr/bin/env bash
# Location: /usr/local/bin/output-context-variables
# Description: Outputs user-scoped context values from the latest run as a flat JSON object.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_MODE="run"
RERUN_NAME=""

usage() {
    cat <<EOF
Usage: output-context-variables [-ap <agent-path>] [-r|--rerun [name]]

Outputs the user-scoped context values from the latest run as a flat JSON
object, read from <agent-path>/outputs/test-context.json.

Options:
   -ap <agent-path>          Override the agent path (default: \$AGENT_PATH or /agent)
   -r, --rerun [name]        Read a rerun's context instead of the full run's.
                             With no name, reads the most recent rerun.
   -h, --help, h, help       Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        -h | --help | h | help)
            usage
            exit 0
            ;;
        -ap)
            if [ -z "${2:-}" ]; then
                echo "ERROR: -ap requires an agent path." >&2
                exit 1
            fi
            AGENT_PATH="$2"
            shift 2
            ;;
        -r | --rerun)
            RESULT_MODE="rerun"
            # The name is optional: consume the next argument only when there is
            # one and it is not another flag.
            if [ -n "${2:-}" ] && [[ "$2" != -* ]]; then
                RERUN_NAME="$2"
                shift
            fi
            shift
            ;;
        *)
            # Rejected rather than ignored: a mistyped selector must not quietly
            # emit the full run's context instead of the rerun's.
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
# shellcheck source=run-qa-lib.sh
for _name in run-qa-lib; do
  _path="${_LIB}/${_name}"
  [ -f "${_path}.sh" ] && _path="${_path}.sh"
  # shellcheck disable=SC1090
  source "${_path}"
done

if is_run_qa_active; then
    echo "ERROR: Testing is in progress ($(run_qa_session_mode) pid: $RUN_QA_ACTIVE_PID). Exporting context variables while testing is in progress isn't supported." >&2
    exit 1
fi

OUTPUT_DIR="$(run_qa_resolve_output_dir "$AGENT_PATH" "$RESULT_MODE" "$RERUN_NAME")"
CONTEXT_FILE="${OUTPUT_DIR}/test-context.json"

if [ "$RESULT_MODE" = "rerun" ]; then
    # stderr only: stdout is machine-read JSON and must stay exactly that.
    echo "🔁 Reading rerun context from ${OUTPUT_DIR}" >&2
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

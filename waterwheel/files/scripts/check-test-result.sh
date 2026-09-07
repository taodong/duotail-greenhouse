#!/usr/bin/env bash
# Location: /usr/local/bin/check-test-result
# Description: Prints the test result, or reports status if a run is in progress.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_MODE="run"
RERUN_NAME=""

usage() {
    cat <<EOF
Usage: check-test-result [-ap <agent-path>] [-r|--rerun [name]]

Prints the exit_condition from the test results, or reports the current status
if a run is in progress.

Options:
   -ap <agent-path>          Override the agent path (default: \$AGENT_PATH or /agent)
   -r, --rerun [name]        Read a rerun's results instead of the full run's.
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
            # print the full run's results as though they were the rerun's.
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
    echo "⏳ Testing is in progress ($(run_qa_session_mode) pid: $RUN_QA_ACTIVE_PID). Results will be available once the run completes."
    exit 0
fi

OUTPUT_DIR="$(run_qa_resolve_output_dir "$AGENT_PATH" "$RESULT_MODE" "$RERUN_NAME")"
RESULTS_FILE="${OUTPUT_DIR}/test-results.json"

if [ "$RESULT_MODE" = "rerun" ]; then
    # stderr, so stdout keeps exactly the contract it has today.
    echo "🔁 Reading rerun results from ${OUTPUT_DIR}" >&2
fi

if [ ! -f "$RESULTS_FILE" ]; then
    echo "ℹ️  No test results found."
    LOG_FILE="${OUTPUT_DIR}/agent.log"
    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "📋 Agent log found:"
        echo ""
        cat "$LOG_FILE"
    fi

    # A rerun that fails before running any task writes no results file at all,
    # and its startup lines land in the top-level agent.log: rerun-qa only calls
    # fileLogger.reconfigure() after loading config and skills. So that log is
    # where an early rerun failure is actually recorded.
    if [ "$RESULT_MODE" = "rerun" ]; then
        STARTUP_LOG="${AGENT_PATH}/outputs/agent.log"
        if [ -f "$STARTUP_LOG" ]; then
            echo ""
            echo "📋 Pre-rerun startup log (${STARTUP_LOG}):"
            echo ""
            cat "$STARTUP_LOG"
        fi
    fi
    exit 0
fi

jq -r '.exit_condition' "$RESULTS_FILE" 2>/dev/null || cat "$RESULTS_FILE"

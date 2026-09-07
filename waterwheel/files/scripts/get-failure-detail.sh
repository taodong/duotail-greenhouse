#!/usr/bin/env bash
# Location: /usr/local/bin/get-failure-detail
# Description: Prints full diagnostic details for the first failed test, or reports status if a run is in progress.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOW_API_LOG=false
RESULT_MODE="run"
RERUN_NAME=""

usage() {
    cat <<EOF
Usage: get-failure-detail [-ap <agent-path>] [-d] [-r|--rerun [name]]

Prints a full diagnostic report for the first failed test, or reports the
current status if a run is in progress.

Options:
   -ap <agent-path>          Override the agent path (default: \$AGENT_PATH or /agent)
   -d                        Include the API log at the end of the report
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
        -d)
            SHOW_API_LOG=true
            shift
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
            # report on the full run instead of the rerun.
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
    exit 0
fi

EXIT_CONDITION=$(jq -r '.exit_condition' "$RESULTS_FILE")
RUN_STATUS=$(jq -r '.status' "$RESULTS_FILE")

if [ "$EXIT_CONDITION" = "All tests passed" ]; then
    echo "✅ No failed tests found in test results."
    exit 0
fi

if [ "$RUN_STATUS" = "incomplete" ]; then
    echo "⚠️  Run did not complete: ${EXIT_CONDITION}"
    exit 0
fi

FAILED_TEST=$(jq 'first(.results[] | select(.status == "failed"))' "$RESULTS_FILE")
if [ -z "$FAILED_TEST" ] || [ "$FAILED_TEST" = "null" ]; then
    echo "✅ No failed tests found in test results."
    exit 0
fi

TEST_FILE=$(echo "$FAILED_TEST" | jq -r '.file')
TEST_LOG_FILE="${TEST_FILE%.md}_log.json"

echo "=== Failed Test Summary ==="
echo "$FAILED_TEST" | jq .

echo ""
echo "=== Test Detail: ${TEST_FILE} ==="
# Task files live outside outputs/ and are the same ones a rerun replays, so
# this path is not affected by the rerun selector.
DETAIL_FILE="${AGENT_PATH}/tasks/${TEST_FILE}"
if [ -f "$DETAIL_FILE" ]; then
    cat "$DETAIL_FILE"
else
    echo "⚠️  File not available: ${DETAIL_FILE}"
fi

echo ""
echo "=== Test Steps: ${TEST_LOG_FILE} ==="
STEPS_FILE="${OUTPUT_DIR}/${TEST_LOG_FILE}"
if [ -f "$STEPS_FILE" ]; then
    cat "$STEPS_FILE"
else
    echo "⚠️  File not available: ${STEPS_FILE}"
fi

echo ""
echo "=== Test Context ==="
CONTEXT_FILE="${OUTPUT_DIR}/test-context.json"
if [ -f "$CONTEXT_FILE" ]; then
    cat "$CONTEXT_FILE"
else
    echo "⚠️  File not available: ${CONTEXT_FILE}"
fi

echo ""
echo "=== Agent Log ==="
LOG_FILE="${OUTPUT_DIR}/agent.log"
if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE"
else
    echo "⚠️  File not available: ${LOG_FILE}"
fi

# A rerun's startup lines land in the top-level agent.log: rerun-qa only calls
# fileLogger.reconfigure() after loading config and skills, so the rerun folder's
# agent.log holds only the post-reconfigure tail.
if [ "$RESULT_MODE" = "rerun" ]; then
    STARTUP_LOG="${AGENT_PATH}/outputs/agent.log"
    if [ -f "$STARTUP_LOG" ]; then
        echo ""
        echo "=== Pre-rerun Startup Log: ${STARTUP_LOG} ==="
        cat "$STARTUP_LOG"
    fi
fi

if [ "$SHOW_API_LOG" = true ]; then
    API_LOG_FILE="${OUTPUT_DIR}/api-log.json"
    if [ -f "$API_LOG_FILE" ]; then
        echo ""
        echo "=== API Log ==="
        cat "$API_LOG_FILE"
    fi
fi

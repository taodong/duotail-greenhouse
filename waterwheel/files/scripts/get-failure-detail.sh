#!/usr/bin/env bash
# Location: /usr/local/bin/get-failure-detail
# Description: Prints full diagnostic details for the first failed test, or reports status if a run is in progress.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOW_API_LOG=false

while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        -ap) AGENT_PATH="$2"; shift 2 ;;
        -d)  SHOW_API_LOG=true; shift ;;
        *)   break ;;
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

RESULTS_FILE="${AGENT_PATH}/outputs/test-results.json"

if is_run_qa_active; then
    echo "⏳ Testing is in progress ($(run_qa_session_mode) pid: $RUN_QA_ACTIVE_PID). Results will be available once the run completes."
    exit 0
fi

if [ ! -f "$RESULTS_FILE" ]; then
    echo "ℹ️  No test results found."
    LOG_FILE="${AGENT_PATH}/outputs/agent.log"
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
DETAIL_FILE="${AGENT_PATH}/tasks/${TEST_FILE}"
if [ -f "$DETAIL_FILE" ]; then
    cat "$DETAIL_FILE"
else
    echo "⚠️  File not available: ${DETAIL_FILE}"
fi

echo ""
echo "=== Test Steps: ${TEST_LOG_FILE} ==="
STEPS_FILE="${AGENT_PATH}/outputs/${TEST_LOG_FILE}"
if [ -f "$STEPS_FILE" ]; then
    cat "$STEPS_FILE"
else
    echo "⚠️  File not available: ${STEPS_FILE}"
fi

echo ""
echo "=== Test Context ==="
CONTEXT_FILE="${AGENT_PATH}/outputs/test-context.json"
if [ -f "$CONTEXT_FILE" ]; then
    cat "$CONTEXT_FILE"
else
    echo "⚠️  File not available: ${CONTEXT_FILE}"
fi

echo ""
echo "=== Agent Log ==="
LOG_FILE="${AGENT_PATH}/outputs/agent.log"
if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE"
else
    echo "⚠️  File not available: ${LOG_FILE}"
fi

if [ "$SHOW_API_LOG" = true ]; then
    API_LOG_FILE="${AGENT_PATH}/outputs/api-log.json"
    if [ -f "$API_LOG_FILE" ]; then
        echo ""
        echo "=== API Log ==="
        cat "$API_LOG_FILE"
    fi
fi

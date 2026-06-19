#!/usr/bin/env bash
# Location: /usr/local/bin/check-test-result
# Description: Prints the test result, or reports status if a run is in progress.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "-ap" ]]; then
    AGENT_PATH="$2"
    shift 2
fi

# shellcheck source=run-qa-lib.sh
# Support both development (.sh) and container (no extension) installs.
_LIB="${SCRIPT_DIR}/run-qa-lib"
# shellcheck disable=SC1090
source "${_LIB}.sh" 2>/dev/null || source "${_LIB}"

RESULTS_FILE="${AGENT_PATH}/outputs/test-results.json"

if is_run_qa_active; then
    echo "⏳ Testing is in progress (run-qa pid: $RUN_QA_ACTIVE_PID). Results will be available once the run completes."
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

jq -r '.exit_condition' "$RESULTS_FILE" 2>/dev/null || cat "$RESULTS_FILE"

#!/usr/bin/env bash
# Location: /usr/local/bin/check-test-result
# Description: Prints the test result, or reports status if a run is in progress.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "-ap" ]]; then
    AGENT_PATH="$2"
    shift 2
fi

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

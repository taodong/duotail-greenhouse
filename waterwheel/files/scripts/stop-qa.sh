#!/bin/bash
# Location: /usr/local/bin/stop-qa
# Description: Stops an existing run-qa process tree if one is active.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${SCRIPT_DIR}/run-qa-lib"
# shellcheck disable=SC1090
source "${_LIB}.sh" 2>/dev/null || source "${_LIB}"

PID_FILE="$RUN_QA_PID_FILE"
AGENT_PID_FILE="$RUN_QA_AGENT_PID_FILE"

RUN_QA_PID=""
AGENT_PID=""

if [ -f "$PID_FILE" ]; then
    RUN_QA_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
fi
if [ -f "$AGENT_PID_FILE" ]; then
    AGENT_PID="$(cat "$AGENT_PID_FILE" 2>/dev/null || true)"
fi

if [ -z "$RUN_QA_PID" ] && [ -z "$AGENT_PID" ]; then
    echo "ℹ️  No tracked run-qa process found."
    exit 0
fi

if [ -n "$AGENT_PID" ]; then
    echo "🛑 Stopping run-qa agent process tree${AGENT_PID:+ (pid: $AGENT_PID)}..."
    terminate_pid_tree "$AGENT_PID"
fi

if [ -n "$RUN_QA_PID" ]; then
    echo "🛑 Stopping run-qa orchestrator${RUN_QA_PID:+ (pid: $RUN_QA_PID)}..."
    terminate_pid_tree "$RUN_QA_PID"
fi

rm -f "$AGENT_PID_FILE" "$PID_FILE"

echo "✅ stop-qa completed."


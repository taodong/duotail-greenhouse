#!/bin/bash
# Location: /usr/local/bin/stop-qa
# Description: Stops an existing run-qa process tree if one is active.

PID_FILE="/tmp/run-qa.pid"
AGENT_PID_FILE="/tmp/run-qa.agent.pid"

terminate_pid_tree() {
    local TARGET_PID=$1
    local CHILD_PID

    if [ -z "$TARGET_PID" ] || ! kill -0 "$TARGET_PID" 2>/dev/null; then
        return
    fi

    for CHILD_PID in $(pgrep -P "$TARGET_PID" 2>/dev/null || true); do
        terminate_pid_tree "$CHILD_PID"
    done

    kill "$TARGET_PID" 2>/dev/null || true
    for _ in {1..20}; do
        if ! kill -0 "$TARGET_PID" 2>/dev/null; then
            return
        fi
        sleep 0.2
    done
    kill -9 "$TARGET_PID" 2>/dev/null || true
}

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


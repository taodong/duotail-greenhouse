#!/usr/bin/env bash
# Shared library for run-qa process management.
# Callers must source this file; do not execute directly.

RUN_QA_PID_FILE="/tmp/run-qa.pid"
RUN_QA_AGENT_PID_FILE="/tmp/run-qa.agent.pid"
RUN_QA_LOCK_FILE="/tmp/run-qa.lock"

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

# Returns 0 if run-qa is active, 1 otherwise.
# Sets RUN_QA_ACTIVE_PID to the orchestrator PID when active.
is_run_qa_active() {
    RUN_QA_ACTIVE_PID=""
    if [ ! -f "$RUN_QA_PID_FILE" ]; then
        return 1
    fi
    local pid
    pid="$(cat "$RUN_QA_PID_FILE" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    RUN_QA_ACTIVE_PID="$pid"
    return 0
}

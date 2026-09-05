#!/bin/bash
# Location: /usr/local/bin/stop-qa
# Description: Stops an existing run-qa or rerun-tests process tree if one is active.
#              Use stop-rerun to target a rerun session specifically.

# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _name in run-qa-lib; do
  _path="${_LIB}/${_name}"
  [ -f "${_path}.sh" ] && _path="${_path}.sh"
  # shellcheck disable=SC1090
  source "${_path}"
done

PID_FILE="$RUN_QA_PID_FILE"
AGENT_PID_FILE="$RUN_QA_AGENT_PID_FILE"
MODE_FILE="$RUN_QA_MODE_FILE"

RUN_QA_PID=""
AGENT_PID=""

if [ -f "$PID_FILE" ]; then
    RUN_QA_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
fi
if [ -f "$AGENT_PID_FILE" ]; then
    AGENT_PID="$(cat "$AGENT_PID_FILE" 2>/dev/null || true)"
fi

SESSION_MODE="$(run_qa_session_mode)"

if [ -z "$RUN_QA_PID" ] && [ -z "$AGENT_PID" ]; then
    # No tracked process, but check if the lock file is still held by an
    # orphaned process (e.g. Xvfb inheriting FD 200 from a prior run).
    if [ -f "$RUN_QA_LOCK_FILE" ] && ! flock -n "$RUN_QA_LOCK_FILE" true 2>/dev/null; then
        LOCK_HOLDER="$(fuser "$RUN_QA_LOCK_FILE" 2>/dev/null | tr -s ' ' '\n' | grep -v '^$' | head -1 || true)"
        if [ -n "$LOCK_HOLDER" ]; then
            echo "⚠️  No tracked process, but lock is held by PID $LOCK_HOLDER. Releasing..."
            terminate_pid_tree "$LOCK_HOLDER"
        fi
        rm -f "$RUN_QA_LOCK_FILE" "$MODE_FILE"
        echo "✅ Stale lock cleared."
    else
        echo "ℹ️  No tracked run-qa or rerun-tests process found."
    fi
    exit 0
fi

if [ -n "$AGENT_PID" ]; then
    echo "🛑 Stopping $SESSION_MODE agent process tree${AGENT_PID:+ (pid: $AGENT_PID)}..."
    terminate_pid_tree "$AGENT_PID"
fi

if [ -n "$RUN_QA_PID" ]; then
    echo "🛑 Stopping $SESSION_MODE orchestrator${RUN_QA_PID:+ (pid: $RUN_QA_PID)}..."
    terminate_pid_tree "$RUN_QA_PID"
fi

rm -f "$AGENT_PID_FILE" "$PID_FILE" "$MODE_FILE"

echo "✅ stop-qa completed."


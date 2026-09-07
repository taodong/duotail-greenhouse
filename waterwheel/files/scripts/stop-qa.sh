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

RUN_QA_PID=""
RUN_QA_START=""
AGENT_PID=""
SESSION_MODE="run-qa"
RECORD_PRESENT=false

# Each PID is validated independently: when an orchestrator is SIGKILLed its
# agent survives reparented, and validating separately lets us still reap it.
if run_qa_read_session; then
    RECORD_PRESENT=true
    SESSION_MODE="$(run_qa_session_mode)"
    if run_qa_pid_matches "$RUN_QA_SESSION_PID" "$RUN_QA_SESSION_START"; then
        RUN_QA_PID="$RUN_QA_SESSION_PID"
        RUN_QA_START="$RUN_QA_SESSION_START"
    fi
    if run_qa_pid_matches "$RUN_QA_SESSION_AGENT_PID" "$RUN_QA_SESSION_AGENT_START"; then
        AGENT_PID="$RUN_QA_SESSION_AGENT_PID"
    fi
fi

if [ -z "$RUN_QA_PID" ] && [ -z "$AGENT_PID" ]; then
    if [ "$RECORD_PRESENT" = true ]; then
        if run_qa_clear_session_if_unlocked; then
            echo "ℹ️  Discarded stale session record (recorded pid ${RUN_QA_SESSION_PID:-unknown} is gone or was replaced)."
        else
            echo "ℹ️  A new session already holds the lock; leaving its record in place."
        fi
    fi
    # No live process, but check if the lock file is still held by an
    # orphaned process (e.g. Xvfb inheriting FD 200 from a prior run).
    if [ -f "$RUN_QA_LOCK_FILE" ] && ! flock -n "$RUN_QA_LOCK_FILE" true 2>/dev/null; then
        # A lock held by a session that started while we were working is not
        # stale. Without this guard the fuser lookup below resolves to that
        # session's own orchestrator and terminates it -- including in the case
        # just reported above as "leaving its record in place" -- and the
        # subsequent rm unlinks a lock file a live process still holds, letting
        # the next run-qa create a fresh one and drive Xvfb concurrently.
        if is_run_qa_active; then
            echo "ℹ️  Lock is held by an active $(run_qa_session_mode) session (pid: $RUN_QA_ACTIVE_PID); leaving it alone."
            exit 0
        fi
        LOCK_HOLDER="$(fuser "$RUN_QA_LOCK_FILE" 2>/dev/null | tr -s ' ' '\n' | grep -v '^$' | head -1 || true)"
        if [ -n "$LOCK_HOLDER" ]; then
            echo "⚠️  No tracked process, but lock is held by PID $LOCK_HOLDER. Releasing..."
            terminate_pid_tree "$LOCK_HOLDER"
        fi
        rm -f "$RUN_QA_LOCK_FILE"
        echo "✅ Stale lock cleared."
    elif [ "$RECORD_PRESENT" != true ]; then
        echo "ℹ️  No tracked run-qa or rerun-tests process found."
    fi
    exit 0
fi

if [ -n "$AGENT_PID" ]; then
    echo "🛑 Stopping $SESSION_MODE agent process tree (pid: $AGENT_PID)..."
    terminate_pid_tree "$AGENT_PID"
fi

if [ -n "$RUN_QA_PID" ]; then
    # Re-validate: terminating the agent above blocks for up to 4s, and killing
    # it makes the orchestrator's `wait` return so it exits on its own. By now
    # the PID validated at the top may be gone or recycled by an unrelated
    # process, and terminate_pid_tree does no identity check of its own.
    if run_qa_pid_matches "$RUN_QA_PID" "$RUN_QA_START"; then
        echo "🛑 Stopping $SESSION_MODE orchestrator (pid: $RUN_QA_PID)..."
        terminate_pid_tree "$RUN_QA_PID"
    else
        echo "ℹ️  $SESSION_MODE orchestrator (pid: $RUN_QA_PID) already exited."
    fi
fi

if ! run_qa_clear_session_if_unlocked; then
    echo "ℹ️  A new session started while stopping; leaving its record in place."
fi

echo "✅ stop-qa completed."

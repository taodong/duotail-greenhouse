#!/bin/bash
# Location: /usr/local/bin/stop-rerun
# Description: Stops an active rerun-tests process tree.
#
# Scoped to rerun sessions on purpose: run-qa and rerun-tests share one lock and one
# session record, so this command validates the record and refuses to terminate a
# run-qa session. Use stop-qa for those, and for stale-lock recovery.

# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _name in run-qa-lib; do
  _path="${_LIB}/${_name}"
  [ -f "${_path}.sh" ] && _path="${_path}.sh"
  # shellcheck disable=SC1090
  source "${_path}"
done

if ! run_qa_read_session; then
    echo "ℹ️  No tracked rerun-tests process found."
    echo "   If a stale lock is blocking a new session, run stop-qa."
    exit 0
fi

RERUN_PID=""
RERUN_START=""
AGENT_PID=""

# Validate identity before consulting the mode, so a stale record is reported as
# stale rather than as an active run-qa session.
if run_qa_pid_matches "$RUN_QA_SESSION_PID" "$RUN_QA_SESSION_START"; then
    RERUN_PID="$RUN_QA_SESSION_PID"
    RERUN_START="$RUN_QA_SESSION_START"
fi
if run_qa_pid_matches "$RUN_QA_SESSION_AGENT_PID" "$RUN_QA_SESSION_AGENT_START"; then
    AGENT_PID="$RUN_QA_SESSION_AGENT_PID"
fi

if [ -z "$RERUN_PID" ] && [ -z "$AGENT_PID" ]; then
    echo "ℹ️  Session record is stale (recorded pid $RUN_QA_SESSION_PID is gone or was replaced)."
    echo "   Nothing stopped. Run stop-qa if a stale lock is blocking a new session."
    run_qa_clear_session_if_unlocked || \
        echo "   A new session already holds the lock; leaving its record in place."
    exit 0
fi

# A record whose mode is missing or unrecognized reads as run-qa, so an
# unidentifiable session is never terminated here.
SESSION_MODE="$(run_qa_session_mode)"

if [ "$SESSION_MODE" != "rerun-tests" ]; then
    echo "⚠️  Active session is $SESSION_MODE${RERUN_PID:+ (pid: $RERUN_PID)}, not a rerun."
    echo "   Nothing stopped. Run stop-qa to stop it."
    exit 1
fi

if [ -n "$AGENT_PID" ]; then
    echo "🛑 Stopping rerun-tests agent process tree (pid: $AGENT_PID)..."
    terminate_pid_tree "$AGENT_PID"
fi

if [ -n "$RERUN_PID" ]; then
    # Re-validate: terminating the agent above blocks for up to 4s, and killing
    # it makes the orchestrator's `wait` return so it exits on its own. By now
    # the PID validated at the top may be gone or recycled by an unrelated
    # process, and terminate_pid_tree does no identity check of its own.
    if run_qa_pid_matches "$RERUN_PID" "$RERUN_START"; then
        echo "🛑 Stopping rerun-tests orchestrator (pid: $RERUN_PID)..."
        terminate_pid_tree "$RERUN_PID"
    else
        echo "ℹ️  rerun-tests orchestrator (pid: $RERUN_PID) already exited."
    fi
fi

if ! run_qa_clear_session_if_unlocked; then
    echo "ℹ️  A new session started while stopping; leaving its record in place."
fi

echo "✅ stop-rerun completed."

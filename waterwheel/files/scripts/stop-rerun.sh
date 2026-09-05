#!/bin/bash
# Location: /usr/local/bin/stop-rerun
# Description: Stops an active rerun-tests process tree.
#
# Scoped to rerun sessions on purpose: run-qa and rerun-tests share one lock and one
# set of PID files, so this command consults the session mode marker and refuses to
# terminate a run-qa session. Use stop-qa for those, and for stale-lock recovery.

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

RERUN_PID=""
AGENT_PID=""

if [ -f "$PID_FILE" ]; then
    RERUN_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
fi
if [ -f "$AGENT_PID_FILE" ]; then
    AGENT_PID="$(cat "$AGENT_PID_FILE" 2>/dev/null || true)"
fi

if [ -z "$RERUN_PID" ] && [ -z "$AGENT_PID" ]; then
    echo "ℹ️  No tracked rerun-tests process found."
    echo "   If a stale lock is blocking a new session, run stop-qa."
    exit 0
fi

# A missing or unrecognized marker reads as run-qa, so an unidentifiable session is
# never terminated here.
SESSION_MODE="$(run_qa_session_mode)"

if [ "$SESSION_MODE" != "rerun-tests" ]; then
    echo "⚠️  Active session is $SESSION_MODE${RERUN_PID:+ (pid: $RERUN_PID)}, not a rerun."
    echo "   Nothing stopped. Run stop-qa to stop it."
    exit 1
fi

if [ -n "$AGENT_PID" ]; then
    echo "🛑 Stopping rerun-tests agent process tree${AGENT_PID:+ (pid: $AGENT_PID)}..."
    terminate_pid_tree "$AGENT_PID"
fi

if [ -n "$RERUN_PID" ]; then
    echo "🛑 Stopping rerun-tests orchestrator${RERUN_PID:+ (pid: $RERUN_PID)}..."
    terminate_pid_tree "$RERUN_PID"
fi

rm -f "$AGENT_PID_FILE" "$PID_FILE" "$MODE_FILE"

echo "✅ stop-rerun completed."

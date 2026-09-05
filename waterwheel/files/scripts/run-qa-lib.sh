#!/usr/bin/env bash
# Shared library for run-qa / rerun-tests process management.
# Callers must source this file; do not execute directly.

RUN_QA_LOCK_FILE="/tmp/run-qa.lock"
RUN_QA_SESSION_FILE="/tmp/run-qa.session"

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

# Echoes a process's start time (clock ticks since boot, field 22 of
# /proc/<pid>/stat). It is fixed for the life of a process, so comparing it
# distinguishes the recorded process from an unrelated one that later inherited
# the same PID. Returns 1 when it cannot be determined.
run_qa_process_start_time() {
    local pid="$1" stat_line rest
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -r "/proc/$pid/stat" ] || return 1
    stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    [ -n "$stat_line" ] || return 1
    # Field 2 (comm) is parenthesized and may itself contain spaces or ')', so
    # drop everything through the last ") " before counting. Field 22 overall is
    # then field 20 of what remains.
    rest="${stat_line##*) }"
    # shellcheck disable=SC2086
    set -- $rest
    [ $# -ge 20 ] || return 1
    printf '%s\n' "${20}"
}

# Writes the session record for the current process:
#   <mode> <orch_pid> <orch_start> <agent_pid> <agent_start>
# "-" marks an unknown or absent field. Written via a temp file and mv'd into
# place so a concurrent reader never sees a torn record.
run_qa_write_session() {
    local mode="$1" agent_pid="${2:--}" agent_start="${3:--}"
    local orch_start tmp

    # Only the lock holder ever writes, so any temp file sitting here is a
    # leftover from a writer that was killed mid-write and can never be live.
    rm -f "${RUN_QA_SESSION_FILE}".* 2>/dev/null || true

    orch_start="$(run_qa_process_start_time "$$")" || orch_start="-"
    tmp="${RUN_QA_SESSION_FILE}.$$"

    if ! printf '%s %s %s %s %s\n' \
        "$mode" "$$" "${orch_start:--}" "${agent_pid:--}" "${agent_start:--}" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$RUN_QA_SESSION_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

# Removes the session record along with any temp file left behind by a write
# that was interrupted before its mv completed.
run_qa_clear_session() {
    rm -f "$RUN_QA_SESSION_FILE" "${RUN_QA_SESSION_FILE}".* 2>/dev/null || true
}

# Records the agent subprocess in the existing record; with no argument (or an
# empty one) clears the agent fields. Must be called by the orchestrator itself.
run_qa_set_agent() {
    local agent_pid="${1:-}" agent_start="-"
    run_qa_read_session || return 1
    if [ -n "$agent_pid" ]; then
        agent_start="$(run_qa_process_start_time "$agent_pid")" || agent_start="-"
    else
        agent_pid="-"
    fi
    run_qa_write_session "$RUN_QA_SESSION_MODE" "$agent_pid" "$agent_start"
}

# Loads the record into RUN_QA_SESSION_{MODE,PID,START,AGENT_PID,AGENT_START}.
# Returns 1 if the record is absent or malformed.
run_qa_read_session() {
    RUN_QA_SESSION_MODE=""
    RUN_QA_SESSION_PID=""
    RUN_QA_SESSION_START=""
    RUN_QA_SESSION_AGENT_PID=""
    RUN_QA_SESSION_AGENT_START=""

    [ -f "$RUN_QA_SESSION_FILE" ] || return 1
    read -r RUN_QA_SESSION_MODE RUN_QA_SESSION_PID RUN_QA_SESSION_START \
            RUN_QA_SESSION_AGENT_PID RUN_QA_SESSION_AGENT_START \
        < "$RUN_QA_SESSION_FILE" || return 1

    case "$RUN_QA_SESSION_PID" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# Returns 0 only if PID is alive AND is the same process the record was written
# for. A recycled PID fails the start-time comparison and is reported as stale.
run_qa_pid_matches() {
    local pid="$1" expected="$2" actual
    case "$pid" in
        ''|-|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1

    # Written in an environment without /proc: nothing to compare against, so
    # fall back to the liveness check alone.
    if [ -z "$expected" ] || [ "$expected" = "-" ]; then
        return 0
    fi

    if ! actual="$(run_qa_process_start_time "$pid")"; then
        echo "⚠️  Cannot read /proc/$pid to verify session identity; proceeding on liveness alone." >&2
        return 0
    fi

    [ "$actual" = "$expected" ]
}

# Returns 0 if a validated run-qa or rerun-tests session is active, 1 otherwise.
# Sets RUN_QA_ACTIVE_PID to the orchestrator PID when active.
is_run_qa_active() {
    RUN_QA_ACTIVE_PID=""
    run_qa_read_session || return 1
    run_qa_pid_matches "$RUN_QA_SESSION_PID" "$RUN_QA_SESSION_START" || return 1
    RUN_QA_ACTIVE_PID="$RUN_QA_SESSION_PID"
    return 0
}

# Echoes the recorded session's mode: "run-qa" or "rerun-tests". A missing or
# unrecognized record reads as "run-qa" so that an unidentifiable session is
# never mistaken for a rerun and terminated by stop-rerun.
run_qa_session_mode() {
    if run_qa_read_session && [ "$RUN_QA_SESSION_MODE" = "rerun-tests" ]; then
        echo "rerun-tests"
    else
        echo "run-qa"
    fi
}

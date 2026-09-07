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

# Removes the session record, but only when no live session holds the lock.
# Terminating the agent can let the old orchestrator exit and release its flock
# before a stopper reaches its cleanup, so a replacement run-qa/rerun-tests may
# already have acquired the lock and written its own record — that record must
# survive. Holding the lock across the removal also closes the gap between the
# check and the rm. Returns 1, removing nothing, when a new session owns it.
run_qa_clear_session_if_unlocked() {
    local rc=0
    exec 201>"$RUN_QA_LOCK_FILE"
    if flock -n 201; then
        run_qa_clear_session
        flock -u 201
    else
        rc=1
    fi
    exec 201>&-
    return "$rc"
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

    # A record written without /proc stores "-" and was handled above, so
    # reaching here means kill -0 succeeded and the /proc read then failed --
    # i.e. the process exited in between. Report it as gone rather than as a
    # match: treating it as live makes check-test-result claim a finished run is
    # still in progress, and makes the stoppers act on a PID they cannot
    # identify.
    if ! actual="$(run_qa_process_start_time "$pid")"; then
        return 1
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

# Normalizes a rerun name to the folder suffix the agent uses. This must be a
# faithful mirror of normalizeRerunName() in the agent's
# src/utils/rerun-output-dir.ts -- any divergence resolves to the wrong folder:
#
#   name.trim().toLowerCase().replace(/\s+/g, "_").replace(/[^a-z0-9_-]/g, "")
#
# In particular it does NOT strip a leading "rerun-": the agent does not, so a
# rerun genuinely named "rerun-login_flow" lives in "rerun-rerun-login_flow".
# Accepting a pasted folder name is handled as a fallback in
# run_qa_resolve_output_dir, where it cannot shadow a real folder.
# Returns 1 when nothing survives normalization.
run_qa_normalize_rerun_name() {
    local name="$1"

    # Trim surrounding whitespace.
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"

    name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    # Collapse whitespace runs, then map to "_", matching /\s+/g -> "_".
    # Note "tr -s SET1 SET2" squeezes repeats of SET2, so squeezing directly
    # into "_" would also collapse underscores the operator actually typed
    # ("login__flow" -> "login_flow"), which the agent preserves.
    name="$(printf '%s' "$name" | tr -s '[:space:]' ' ')"
    name="${name// /_}"
    name="$(printf '%s' "$name" | tr -cd 'a-z0-9_-')"

    [ -n "$name" ] || return 1
    printf '%s\n' "$name"
}

# Echoes the directory a reader command should read results from.
#   run_qa_resolve_output_dir <agent_path> <mode> [name]
#
# mode "run"   -> "<agent_path>/outputs"
# mode "rerun" -> "<agent_path>/outputs/rerun-<normalized name>", or, with no
#                 name, the most recently modified "<agent_path>/outputs/rerun-*".
#
# Returns 1 with a message on stderr when the requested folder does not exist.
# Callers must let that failure surface rather than falling back to outputs/:
# printing the full run's result as though it were the rerun's is exactly the
# failure this selector exists to remove.
run_qa_resolve_output_dir() {
    local agent_path="$1" mode="$2" name="${3:-}"
    local outputs="${agent_path}/outputs" dir normalized alt

    if [ "$mode" != "rerun" ]; then
        printf '%s\n' "$outputs"
        return 0
    fi

    if [ -n "$name" ]; then
        if ! normalized="$(run_qa_normalize_rerun_name "$name")"; then
            echo "ERROR: rerun name \"$name\" normalizes to an empty string." >&2
            return 1
        fi
        dir="${outputs}/rerun-${normalized}"
        if [ -d "$dir" ]; then
            printf '%s\n' "$dir"
            return 0
        fi

        # Convenience for an operator who pasted a folder name from a listing.
        # Strictly a fallback: the literal name always wins, so a rerun really
        # named "rerun-login_flow" (folder "rerun-rerun-login_flow") can never
        # be shadowed by the unrelated rerun named "login flow".
        case "$normalized" in
            rerun-?*)
                alt="${outputs}/rerun-${normalized#rerun-}"
                if [ -d "$alt" ]; then
                    printf '%s\n' "$alt"
                    return 0
                fi
                ;;
        esac

        echo "ERROR: no rerun output folder at ${dir}." >&2
        return 1
    fi

    # No name: the most recently modified rerun-* folder. The auto-numbered
    # suffix is the lowest free integer rather than a sequence (deleting
    # rerun-2 makes the next unnamed rerun reuse it), and named folders carry
    # no number at all, so mtime is the only reliable "latest".
    # "ls -dt" behaves the same on GNU and BSD; "find -printf" is GNU-only and
    # these scripts also run on the host in dev.
    # shellcheck disable=SC2012 # find -printf is GNU-only; folder names
    # here are always "rerun-<[a-z0-9_-]+>", so ls is safe and portable.
    dir="$(ls -dt "${outputs}"/rerun-*/ 2>/dev/null | head -1 || true)"
    dir="${dir%/}"

    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        echo "ERROR: no rerun output folder found under ${outputs}." >&2
        echo "       Run rerun-tests first, or drop --rerun to read the full run's results." >&2
        return 1
    fi

    printf '%s\n' "$dir"
}

#!/bin/bash
# Location: /usr/local/bin/rerun-tests
# Description: Orchestrates Xvfb, Playwright, and Email MCP services, then replays a
#              subset of tasks via the agent's rerun entry point (dist/rerun-qa.cjs).
#
# Unlike run-qa, this command never cleans /agent/outputs: the rerun seeds itself from
# the previous full run's outputs/checkpoints/ and outputs/test-results.json, and writes
# its own results to an outputs/rerun-* subfolder.

# --- 0. PARSE ARGUMENTS ---
usage() {
    cat <<USAGE
Usage: rerun-tests

Replays the tasks listed in the rerun-config file (RERUN_CONFIG_PATH, default
./instructions/rerun-config.json), seeded from a checkpoint captured by the most
recent full run-qa run. Takes no options.
USAGE
}

for arg in "$@"; do
    case $arg in
        -h|--help|h|help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# --- 0.1 SINGLE-INSTANCE LOCK ---
# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _name in run-qa-lib; do
  _path="${_LIB}/${_name}"
  [ -f "${_path}.sh" ] && _path="${_path}.sh"
  # shellcheck disable=SC1090
  source "${_path}"
done

# run-qa and rerun-tests share one lock: both drive the same Xvfb display and the
# same MCP services, so they must never run concurrently.
LOCK_FILE="$RUN_QA_LOCK_FILE"
PID_FILE="$RUN_QA_PID_FILE"
AGENT_PID_FILE="$RUN_QA_AGENT_PID_FILE"
MODE_FILE="$RUN_QA_MODE_FILE"
AGENT_PID=""

cleanup_lock() {
    if [ -n "$AGENT_PID" ]; then
        terminate_pid_tree "$AGENT_PID"
    fi

    # Only clear the session files if this process actually owns the session.
    # run-qa and rerun-tests share these paths, so an invocation that bounced
    # off the lock must leave the running session's files — including the agent
    # PID file — intact, or stop-qa/stop-rerun lose their handle on the agent.
    if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null || true)" = "$$" ]; then
        rm -f "$PID_FILE" "$MODE_FILE" "$AGENT_PID_FILE"
    fi
}

handle_shutdown() {
    exit 143
}

trap cleanup_lock EXIT
trap handle_shutdown INT TERM

# Keep this FD open for the lifetime of the script so the lock is held.
exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    PREV_PID=""
    if [ -f "$PID_FILE" ]; then
        PREV_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    fi
    PREV_MODE="$(run_qa_session_mode)"
    echo "❌ ERROR: $PREV_MODE is already running${PREV_PID:+ (pid: $PREV_PID)}."
    if [ "$PREV_MODE" = "rerun-tests" ]; then
        echo "   Run stop-rerun first, then start a new rerun-tests session."
    else
        echo "   Run stop-qa first, then start a new rerun-tests session."
    fi
    exit 1
fi

echo "$$" > "$PID_FILE"
echo "rerun-tests" > "$MODE_FILE"

echo "🔁 [RERUN-ORCHESTRATOR] Preparing environment..."

# --- 1. SETTINGS & PATHS ---
LOG_FILE="/agent/outputs/firewall.log"
AGENT_DIR="/agent"
OUTPUT_DIR="$AGENT_DIR/outputs"
AGENT_CONFIG_FILE="$AGENT_DIR/config/agent-config.json"
DISPLAY_ID=":99"
export DISPLAY=$DISPLAY_ID

# Deliberately no output cleanup here: the rerun reads outputs/checkpoints/ and
# outputs/test-results.json from the previous full run.
echo "📁 Preserving $OUTPUT_DIR (the rerun seeds from its checkpoints)."

# --- 1.1 PRE-FLIGHT: RERUN CONFIG MUST EXIST ---
# Resolution order mirrors the agent: process env, then the agent-config default,
# then the hardcoded fallback. Relative paths resolve against the agent's cwd.
resolve_rerun_config_path() {
    local path="${RERUN_CONFIG_PATH:-}"

    if [ -z "$path" ] && [ -f "$AGENT_CONFIG_FILE" ]; then
        path="$(jq -r '.["env-params"][]? | select(.name == "RERUN_CONFIG_PATH") | .default // empty' \
            "$AGENT_CONFIG_FILE" 2>/dev/null || true)"
    fi

    if [ -z "$path" ] || [ "$path" = "null" ]; then
        path="./instructions/rerun-config.json"
    fi

    case "$path" in
        /*) echo "$path" ;;
        *)  echo "${AGENT_DIR}/${path#./}" ;;
    esac
}

RERUN_CONFIG_FILE="$(resolve_rerun_config_path)"

if [ ! -f "$RERUN_CONFIG_FILE" ]; then
    echo "❌ ERROR: rerun config not found at $RERUN_CONFIG_FILE."
    echo "   Create it with, for example:"
    echo "     printf '{\"flow\":[{\"file\":\"test-2.md\"}]}' | upload-instruction-file rerun-config.json"
    echo "   Override the location with the RERUN_CONFIG_PATH agent parameter."
    exit 1
fi

echo "📄 Using rerun config: $RERUN_CONFIG_FILE"

# --- 2. HELPER FUNCTIONS ---
refresh_service() {
    local SERVICE=$1
    local PORT=$2
    echo "♻️  Force-refreshing $SERVICE on port $PORT..."

    # 1. Tell Supervisor to stop the service first
    supervisorctl stop "$SERVICE" >/dev/null 2>&1

    # 2. Hard-kill any "ghost" processes still holding the port
    # This clears the "Port already in use" error for Java
    fuser -k "$PORT/tcp" >/dev/null 2>&1

    # 3. Small "settle" time for the OS kernel (0.5s)
    sleep 0.5

    # 4. Start it fresh
    supervisorctl start "$SERVICE"
}

wait_for_port() {
    local PORT=$1
    local NAME=$2
    echo "⏳ Waiting for $NAME on port $PORT..."
    for i in {1..15}; do
        # Checks if anything is listening on the port (v4 or v6)
        if ss -tulpn | grep -q ":$PORT"; then
            echo "✅ $NAME is active!"
            return 0
        fi
        sleep 1
    done
    echo "❌ ERROR: $NAME failed to bind to port $PORT."
    return 1
}

# --- 3. START VIRTUAL DISPLAY (XVFB) ---
if ! pgrep -x "Xvfb" > /dev/null; then
    echo "🖥️  Starting Virtual Display $DISPLAY_ID..."
    # 2>/dev/null silences the 'Could not resolve keysym' warnings
    Xvfb $DISPLAY_ID -screen 0 1280x1024x24 2>/dev/null 200>&- &

    # Verify Xvfb is actually rendering
    if ! timeout 10 bash -c "until xdpyinfo -display $DISPLAY_ID >/dev/null 2>&1; do sleep 1; done"; then
        echo "❌ ERROR: Xvfb failed to start."
        exit 1
    fi
    echo "✅ Virtual Display ready."
fi

# --- 4. LAUNCH MCP SERVICES ---
if [ "$ENABLE_PLAYWRIGHT_MCP" = "true" ]; then
    refresh_service "playwright-mcp" 3000
    wait_for_port 3000 "Playwright MCP" || exit 1
fi

if [ "$ENABLE_EMAIL_MCP" = "true" ]; then
    refresh_service "email-mcp" 3002
    wait_for_port 3002 "Email MCP" || exit 1
fi

# --- 5. EXECUTE RERUN TASK ---
echo "🤖 Handoff to AgentUser..."

# Export all current env vars to a profile script so agentuser inherits them
printenv | grep -v "^HOME=\|^USER=\|^SHELL=\|^PATH=" | while IFS= read -r line; do
    echo "export $(echo "$line" | sed 's/=/=\"/;s/$/"/')"
done > /etc/profile.d/container_env.sh
chmod 644 /etc/profile.d/container_env.sh

# Use 'su' to run the agent as the non-root user for security
echo "🔁 Replaying tasks from rerun-config. Running: node dist/rerun-qa.cjs"
su - agentuser -c "cd /agent && node dist/rerun-qa.cjs" 200>&- &

AGENT_PID=$!
echo "$AGENT_PID" > "$AGENT_PID_FILE"

wait "$AGENT_PID"
AGENT_EXIT_CODE=$?
AGENT_PID=""
rm -f "$AGENT_PID_FILE"

if [ "$AGENT_EXIT_CODE" -ne 0 ]; then
    exit "$AGENT_EXIT_CODE"
fi

# --- 6. CLEANUP (Optional) ---
# Uncomment the line below if you want services to stop after the agent finishes
supervisorctl stop all

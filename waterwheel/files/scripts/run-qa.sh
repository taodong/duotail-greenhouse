#!/bin/bash
# Location: /usr/local/bin/run-qa
# Description: Orchestrates Xvfb, Playwright, and Email MCP services.

# --- 0. PARSE ARGUMENTS ---
DRY_RUN=false
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
    esac
done

echo "🔄 [QA-ORCHESTRATOR] Preparing fresh environment..."

# --- 1. SETTINGS & PATHS ---
LOG_FILE="/agent/outputs/firewall.log"
OUTPUT_DIR="/agent/outputs"
DISPLAY_ID=":99"
export DISPLAY=$DISPLAY_ID

echo "🧹 Cleaning output contents in $OUTPUT_DIR..."
if [ -d "$OUTPUT_DIR" ]; then
    find "$OUTPUT_DIR" -mindepth 1 -delete
else
    echo "ℹ️  Output directory $OUTPUT_DIR does not exist. Skipping cleanup."
fi

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
    Xvfb $DISPLAY_ID -screen 0 1280x1024x24 2>/dev/null &

    # Verify Xvfb is actually rendering
    if ! timeout 10 bash -c "until xdpyinfo -display $DISPLAY_ID >/dev/null 2>&1; do sleep 1; done"; then
        echo "❌ ERROR: Xvfb failed to start."
        exit 1
    fi
    echo "✅ Virtual Display ready."
fi

# --- 4. LAUNCH MCP SERVICES ---
if [ "$ENABLE_PLAYWRIGHT" = "true" ]; then
    refresh_service "playwright-mcp" 3000
    wait_for_port 3000 "Playwright MCP" || exit 1
fi

if [ "$ENABLE_EMAIL" = "true" ]; then
    refresh_service "email-mcp" 3002
    wait_for_port 3002 "Email MCP" || exit 1
fi

# --- 5. EXECUTE AGENT TASK ---
echo "🤖 Handoff to AgentUser..."

# Export all current env vars to a profile script so agentuser inherits them
printenv | grep -v "^HOME=\|^USER=\|^SHELL=\|^PATH=" | while IFS= read -r line; do
    echo "export $(echo "$line" | sed 's/=/=\"/;s/$/"/')"
done > /etc/profile.d/container_env.sh
chmod 644 /etc/profile.d/container_env.sh

# Use 'su' to run the agent as the non-root user for security
if [ "$DRY_RUN" = "true" ]; then
    echo "🧪 Dry-run mode enabled. Running: npm run dry-run"
    su - agentuser -c "cd /agent && npm run dry-run"
else
    su - agentuser -c "cd /agent && npm start"
fi

# --- 6. CLEANUP (Optional) ---
# Uncomment the line below if you want services to stop after the agent finishes
supervisorctl stop all
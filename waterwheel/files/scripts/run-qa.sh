#!/bin/bash
# Location: /usr/local/bin/run-qa
# Description: Orchestrates Xvfb, Playwright, and Email MCP services.

echo "🔄 [QA-ORCHESTRATOR] Preparing fresh environment..."

# --- 1. SETTINGS & PATHS ---
LOG_FILE="/agent/outputs/firewall.log"
DISPLAY_ID=":99"
export DISPLAY=$DISPLAY_ID

# --- 2. HELPER FUNCTIONS ---
refresh_service() {
    local SERVICE=$1
    echo "♻️  Refreshing $SERVICE..."
    # Ensure any existing 'zombie' processes on the port are cleared
    # (e.g., 3000 for playwright, 3002 for email)
    if [ "$SERVICE" == "playwright-mcp" ]; then PORT=3000; else PORT=3002; fi
    fuser -k $PORT/tcp 2>/dev/null

    # Use supervisor to manage the lifecycle
    supervisorctl restart "$SERVICE" || supervisorctl start "$SERVICE"
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
    if ! timeout 5 bash -c "until xdpyinfo -display $DISPLAY_ID >/dev/null 2>&1; do sleep 1; done"; then
        echo "❌ ERROR: Xvfb failed to start."
        exit 1
    fi
    echo "✅ Virtual Display ready."
fi

# --- 4. LAUNCH MCP SERVICES ---
if [ "$ENABLE_PLAYWRIGHT" = "true" ]; then
    refresh_service "playwright-mcp"
    wait_for_port 3000 "Playwright MCP" || exit 1
fi

if [ "$ENABLE_EMAIL" = "true" ]; then
    refresh_service "email-mcp"
    wait_for_port 3002 "Email MCP" || exit 1
fi

# --- 5. EXECUTE AGENT TASK ---
echo "🤖 Handoff to AgentUser..."
# Use 'su' to run the agent as the non-root user for security
# We use --preserve-environment to keep our DISPLAY and ENABLE flags
# su - agentuser -c "cd /agent && npm start"

# --- 6. CLEANUP (Optional) ---
# Uncomment the line below if you want services to stop after the agent finishes
# supervisorctl stop all
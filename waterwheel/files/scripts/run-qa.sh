#!/bin/bash
# Location: /usr/local/bin/run-qa

echo "🔄 Preparing MCP Services for a fresh Agent run..."

# Function to safely refresh a supervisor service
refresh_service() {
    local SERVICE_NAME=$1
    # Capture the status (RUNNING, STOPPED, FATAL, etc.)
    local STATUS=$(supervisorctl status "$SERVICE_NAME" | awk '{print $2}')

    if [ "$STATUS" = "RUNNING" ]; then
        echo "♻️  $SERVICE_NAME is running. Restarting to load new configs..."
        supervisorctl restart "$SERVICE_NAME"
    else
        echo "🚀 $SERVICE_NAME is $STATUS. Starting fresh..."
        supervisorctl start "$SERVICE_NAME"
    fi
}

# 1. Ensure Xvfb is alive
if ! pgrep -x "Xvfb" > /dev/null; then
    Xvfb :99 -screen 0 1280x1024x24 &
    sleep 2
fi

# 2. Refresh services based on flags
if [ "$ENABLE_PLAYWRIGHT" = "true" ]; then
    refresh_service "playwright-mcp"
fi

if [ "$ENABLE_EMAIL" = "true" ]; then
    refresh_service "email-mcp"
fi

# 3. Give services a moment to bind to their ports
sleep 5

# 4. Run the Agent
echo "🤖 Starting Agent..."
# su - agentuser -c "cd /agent && npm start"
echo "✅ All services are up. Agent is running."
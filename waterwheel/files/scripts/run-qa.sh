#!/bin/bash

# 1. Clean up old runs
echo "Cleaning up existing processes..."
pkill -f "node" || true
pkill -f "java" || true
rm -f /tmp/.X99-lock

# 2. Start Virtual Display
Xvfb :99 -screen 0 1280x1024x24 &
sleep 2

# 3. Start Playwright MCP with Hardware-Level Restrictions
# This uses the --allowed-origins flag to prevent the agent
# from visiting unauthorized sites.
echo "Starting Playwright MCP Server..."
npx @playwright/mcp@latest \
  --allowed-origins "$(cat /agent/instructions/allowed_origins.txt)" \
  --port 3000 &

# 4. Start Java Email MCP (Spring Boot)
echo "📧 Starting Java Email MCP..."
java -Xmx256m -jar /services/email/email-mcp.jar &

# 5. Start the AI Agent Manager
echo "Starting AI Agent Manager..."
# npm start
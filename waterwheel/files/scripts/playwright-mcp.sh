#!/bin/bash
# Location: /usr/local/bin/playwright-mcp

echo "🌐 Processing Playwright YAML Security Rules..."

# 1. Paths
SYSTEM_YAML="/services/playwright/allowed-domains.yaml"
AGENT_YAML="/agent/instructions/allowed-domains.yaml"
LOG_FILE="/agent/outputs/firewall.log"
DEFAULT_ORIGIN="http://localhost"

# 2. Select the source file
if [ -f "$AGENT_YAML" ]; then
    echo "📂 Found custom YAML whitelist at $AGENT_YAML"
    SOURCE_FILE="$AGENT_YAML"
elif [ -f "$SYSTEM_YAML" ]; then
    echo "📂 Using system YAML whitelist at $SYSTEM_YAML"
    SOURCE_FILE="$SYSTEM_YAML"
else
    SOURCE_FILE=""
fi

# 3. Parse YAML with yq
if [ -n "$SOURCE_FILE" ]; then
    # yq 'join(",")' takes the 'allowed' array and turns it into: "url1,url2,url3"
    ALLOWED=$(yq '.allowed | join(",")' "$SOURCE_FILE" 2>/dev/null)
fi

# 4. Fallback and Validation
if [ -z "$ALLOWED" ] || [ "$ALLOWED" == "null" ]; then
    echo "⚠️  YAML parsing failed or was empty. Using default: $DEFAULT_ORIGIN"
    ALLOWED=$DEFAULT_ORIGIN
fi

echo "✅ Final Allowed Origins: $ALLOWED"

# 5. Start Playwright MCP
# - NPM_CONFIG_YES=true: Bypasses the "Canceled" error by auto-confirming
# - --package: Explicitly tells npx which package to use
# - -- : Separates npx flags from the MCP server flags
export NPM_CONFIG_YES=true

# If FIREWALL_DEBUG=true, we enable Playwright's verbose logging
if [ "$FIREWALL_DEBUG" = "true" ]; then
    echo "🐞 Firewall Debug Mode: ON (Logging to $LOG_FILE)"
    export DEBUG="pw:browser,pw:mcp:firewall" # Capture browser & firewall events

    # Run and redirect output to the log file
    exec npx --yes @playwright/mcp@latest \
      --allowed-origins "$ALLOWED" \
      --host 0.0.0.0 \
      --port 3000 >> "$LOG_FILE" 2>&1
else
    # Standard run (logs handled by Supervisor)
    exec npx --yes @playwright/mcp@latest \
      --allowed-origins "$ALLOWED" \
      --host 0.0.0.0 \
      --port 3000
fi
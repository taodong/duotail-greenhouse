#!/bin/bash
# Location: /usr/local/bin/playwright-mcp

echo "🌐 Processing Playwright YAML Security Rules..."

# 1. Paths
SYSTEM_PERMISSION_YAML="/services/playwright/allowed-domains.yaml"
AGENT_PERMISSION_YAML="/agent/instructions/allowed-domains.yaml"
SYSTEM_MCP_CONFIG="/services/playwright/playwright-mcp-config.json"
AGENT_MCP_CONFIG="/agent/instructions/mcp.config.json"
LOG_FILE="/agent/outputs/firewall.log"
DEFAULT_ORIGIN="http://localhost;about:blank"

# 1.1 Resolve optional Playwright MCP config file
if [ -f "$AGENT_MCP_CONFIG" ]; then
    echo "📂 Found custom MCP config at $AGENT_MCP_CONFIG"
    MCP_CONFIG="$AGENT_MCP_CONFIG"
elif [ -f "$SYSTEM_MCP_CONFIG" ]; then
    echo "📂 Using system MCP config at $SYSTEM_MCP_CONFIG"
    MCP_CONFIG="$SYSTEM_MCP_CONFIG"
else
    MCP_CONFIG=""
fi

# 2. Select the source file
if [ -f "$AGENT_PERMISSION_YAML" ]; then
    echo "📂 Found custom YAML whitelist at $AGENT_PERMISSION_YAML"
    SOURCE_FILE="$AGENT_PERMISSION_YAML"
elif [ -f "$SYSTEM_PERMISSION_YAML" ]; then
    echo "📂 Using system YAML whitelist at $SYSTEM_PERMISSION_YAML"
    SOURCE_FILE="$SYSTEM_PERMISSION_YAML"
else
    SOURCE_FILE=""
fi

# 3. Parse YAML with yq
if [ -n "$SOURCE_FILE" ]; then
    # MCP expects semicolon-separated origins in --allowed-origins.
    ALLOWED=$(yq -r '.allowed | join(";")' "$SOURCE_FILE" 2>/dev/null)

    # Keep about:blank available when loading domains from YAML.
    if [ -n "$ALLOWED" ] && [ "$ALLOWED" != "null" ]; then
        case ";$ALLOWED;" in
            *";about:blank;"*) ;;
            *) ALLOWED="$ALLOWED;about:blank" ;;
        esac
    fi
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

MCP_ARGS=(
  --browser chromium
  --allowed-origins "$ALLOWED"
  --host 0.0.0.0
  --port 3000
)

if [ -n "$MCP_CONFIG" ]; then
    MCP_ARGS+=(--config "$MCP_CONFIG")
fi

# If FIREWALL_DEBUG=true, we enable Playwright's verbose logging
if [ "$FIREWALL_DEBUG" = "true" ]; then
    echo "🐞 Firewall Debug Mode: ON (Logging to $LOG_FILE)"
    export DEBUG="pw:browser,pw:mcp:firewall" # Capture browser & firewall events

    # Run and redirect output to the log file
    exec npx --yes @playwright/mcp@0.0.70 "${MCP_ARGS[@]}" >> "$LOG_FILE" 2>&1
else
    # Standard run (logs handled by Supervisor)
    exec npx --yes @playwright/mcp@0.0.70 "${MCP_ARGS[@]}"
fi
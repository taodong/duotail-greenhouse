# Waterwheel

Waterwheel defines the agent for web testing.

## Envrionment Variables
Variable | Description | Default
--- | --- | ---
ENABLE_PLAYWRIGHT | Enable Playwright MCP | true
ENABLE_EMAIL | Enable Email MCP | true
FIREWALL_DEBUG | Enable firewall debug logs | false

## Local MCP port assignment
Port | Service | Responsibility
--- | --- | ---
3000 | playwright-mcp | Browser automation, clicking, and scraping.
3001 | email-mcp | Sending test emails.


## Build
### Build locally
```bash
export DOCKER_BUILDKIT=1

docker build --ssh default -t taojdcn/duotail-waterwheel:latest-mac .
```

### Multi-Platform Build
```bash
export DOCKER_BUILDKIT=1

docker buildx build --platform linux/amd64,linux/arm64 --ssh default -t taojdcn/duotail-waterwheel:latest --load .
```
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
DOCKER_BUILDKIT=1 docker build --ssh default="$SSH_AUTH_SOCK" -t taojdcn/duotail-waterwheel:latest-mac .
```

### Multi-Platform Build
```bash
export DOCKER_BUILDKIT=1

docker buildx build --platform linux/amd64,linux/arm64 --ssh default="$SSH_AUTH_SOCK" -t taojdcn/duotail-waterwheel:latest --push .
```

> Note: For multi-platform images, use `--push` (not `--load`). `--load` only supports loading a single-platform image into your local Docker engine.

## Configuration

### Permissions
Playwright MCP allowed domains should be put under `/agent/instructions/allowed_domains`. Domains are listed under `allowed` as an array

```yaml
allowed:
  - host.docker.internal:8080
  - host.docker.internal:8025
```

Email MCP permissions should be configured under `/agent/instructions/email-permissions.yaml`.

```yaml
from:
  domains:
    - "*"
    - "good_domain.com"
  emails:
    - "allowed@example.com"
    - "*"
to:
  domains:
    - "to.example.com"
  emails:
    - "allowed@example.com"
    - "still-not-an-email"
batchSize: 100
```
# Waterwheel

Waterwheel defines the agent for web testing.

## Environment Variables
Variable | Description | Default
--- | --- | ---
ENABLE_PLAYWRIGHT_MCP | Enable Playwright MCP | true
ENABLE_EMAIL_MCP | Enable Email MCP | true
FIREWALL_DEBUG | Enable firewall debug logs | false

## Local MCP port assignment
Port | Service | Responsibility
--- | --- | ---
3000 | playwright-mcp | Browser automation, clicking, and scraping.
3002 | email-mcp | Sending test emails.

## Build
### Build locally
```bash
DOCKER_BUILDKIT=1 docker build --ssh default="$SSH_AUTH_SOCK" -t taojdcn/duotail-waterwheel:latest-mac .
```

### Refresh agent code during build (without rebuilding `system-deps`)
`waterwheel/Dockerfile` supports `AGENT_CLONE_BUSTER` in the `agent-builder` stage. Pass a unique value when you want to force a fresh clone of the agent repository.

```bash
DOCKER_BUILDKIT=1 docker build \
  --ssh default="$SSH_AUTH_SOCK" \
  --build-arg AGENT_CLONE_BUSTER="$(date +%s)" \
  -t taojdcn/duotail-waterwheel:latest-mac .
```

Using `AGENT_CLONE_BUSTER` invalidates the clone layer in `agent-builder` (and following layers in that stage), while cached layers in `system-deps` remain reusable.

Note: if the previous build used a different `AGENT_CLONE_BUSTER` value (for example `1`) and the current build uses the default (`0`), Docker treats that as a different cache key and the clone step may run once to populate that cache variant.

### Multi-Platform Build
```bash
export DOCKER_BUILDKIT=1

docker buildx build --platform linux/amd64,linux/arm64 --ssh default="$SSH_AUTH_SOCK" -t taojdcn/duotail-waterwheel:latest --push .
```

### Multi-Platform Build with fresh agent source
```bash
export DOCKER_BUILDKIT=1

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --ssh default="$SSH_AUTH_SOCK" \
  --build-arg AGENT_CLONE_BUSTER="$(date +%s)" \
  -t taojdcn/duotail-waterwheel:latest \
  --push .
```

## run-qa Usage

`run-qa` is the entrypoint script that orchestrates all MCP services and launches the agent.

```bash
run-qa [OPTIONS]
```

### Options
Option | Description
--- | ---
_(none)_ | Start all enabled services and run the agent with `npm start`
`--dry-run` | Start all enabled services but run the agent with `npm dry-run` instead of `npm start`

### Examples
```bash
# Normal run
run-qa

# Dry-run mode
run-qa --dry-run
```

## Configuration

### Permissions
Playwright MCP allowed domains should be put under `/agent/instructions/allowed_domains`. Domains are listed under `allowed` as an array
Playwright MCP allowed domains should be put under `/agent/instructions/allowed-domains.yaml`. For backward compatibility, `/agent/instructions/allowed_domains.yaml` and `/agent/instructions/allowed_domains` are also accepted. Domains are listed under `allowed` as an array.

```yaml
allowed:
  - http://host.docker.internal:8080
  - http://host.docker.internal:8025
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

### Global Context
For global variables used by all tests, create a `global-context.json` file and assign its path to environment variable `GLOBAL_CONTEXT`. The content of the file should be a JSON object.

```json
{
    "REGISTER_URL": "http://host.docker.internal:8080/register",
    "LOGIN_URL": "http://host.docker.internal:8080/login",
    "EMAIL_URL": "http://host.docker.internal:8025"
}
```

## Security & Permissions

### Filesystem Permission Matrix

| Path | Owner:Group | Mode | `agentuser` access | Notes |
| --- | --- | --- | --- | --- |
| `/agent` | `agentuser:agentgroup` | varies | Mostly read/write in owned tree | Copied with `--chown=agentuser:agentgroup` in `Dockerfile` |
| `/agent/instructions` | `root:agentgroup` | `550` | Read + traverse, no write | Policy/config files mounted here are read-only at runtime |
| `/agent/tasks` | `root:agentgroup` | `550` | Read + traverse, no write | Task input files are read-only at runtime |
| `/agent/outputs` | `agentuser:agentgroup` | `770` | Full rwx | Agent writes logs and output artifacts here |
| `/agent/bin` | `agentuser:agentgroup` | `770` | Full rwx | Writable bin directory for agent use |
| `/services/playwright` | `root:root` | `700` | No access | Playwright MCP service directory, root-only |
| `/services/playwright/allowed-domains.yaml` | `root:root` | default file mode | Not accessible (parent dir `700`) | System fallback domain allowlist |
| `/services/email` | `root:root` | `700` | No access | Email MCP service directory, root-only |
| `/services/email/email-mcp.jar` | `root:root` | default file mode | Not accessible (parent dir `700`) | Email MCP JAR, loaded by service script |
| `/usr/local/bin/run-qa` | `root:root` | `700` | Cannot execute | Container entrypoint script |
| `/usr/local/bin/playwright-mcp` | `root:root` | `700` | Cannot execute | Playwright MCP launch script |
| `/usr/local/bin/email-mcp` | `root:root` | `700` | Cannot execute | Email MCP launch script |
| `/etc/profile.d/container_env.sh` | `root:root` | `644` | Read-only | Environment variables forwarded from root to `agentuser` |

### Command Availability Matrix

| Command / Action | Root | `agentuser` | Invocation path |
| --- | --- | --- | --- |
| `run-qa` | ✅ | ❌ | `/usr/local/bin/run-qa` (mode `700`) |
| `playwright-mcp` | ✅ | ❌ | Started by Supervisor (`supervisord.conf`) |
| `email-mcp` | ✅ | ❌ | Started by Supervisor (`supervisord.conf`) |
| `supervisorctl start/stop` | ✅ | ❌ | Used inside `run-qa.sh` |
| `node dist/index.cjs` | ✅ | ✅ | `su - agentuser -c "cd /agent && node dist/index.cjs"` |
| `node dist/dry-run.cjs` | ✅ | ✅ | `su - agentuser -c "cd /agent && node dist/dry-run.cjs"` |

### Effective Runtime Permissions (Summary)

| Area | `agentuser` effective permission |
| --- | --- |
| Agent execution | Runs as non-root via `su - agentuser` |
| `/agent/instructions` policies | Read-only — cannot self-modify policy files |
| MCP service binaries/control | No direct execute or control |
| `/services/*` internals | No direct access |
| Output/log artifacts in `/agent/outputs` | Full write access |


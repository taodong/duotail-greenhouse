# Waterwheel

Waterwheel defines the agent for web testing.

## Environment Variables
| Variable | Description | Default |
| --- | --- | --- |
| ENABLE_PLAYWRIGHT_MCP | Enable Playwright MCP | true |
| ENABLE_EMAIL_MCP | Enable Email MCP | true |
| FIREWALL_DEBUG | Enable firewall debug logs | false |

## Local MCP port assignment
| Port | Service | Responsibility |
| --- | --- | --- |
| 3000 | playwright-mcp | Browser automation, clicking, and scraping. |
| 3002 | email-mcp | Sending test emails. |

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

Only one `run-qa` process can run at a time. If another `run-qa` session is already active, the command exits and asks you to run `stop-qa` first.

```bash
run-qa [OPTIONS]
```

### Options
| Option | Description |
| --- | --- |
| _(none)_ | Start all enabled services and run the agent with `npm start` |
| `--dry-run` | Start all enabled services but run the agent with `npm dry-run` instead of `npm start` |

### Examples
```bash
# Normal run
run-qa

# Dry-run mode
run-qa --dry-run

# If a previous run-qa session is still active, stop it first
stop-qa
run-qa
```

## stop-qa Usage

`stop-qa` stops the currently tracked `run-qa` process tree, including the launched agent subprocess, if one exists.

```bash
stop-qa
```

### Examples
```bash
# Stop the current run-qa session, if any
stop-qa

# Restart with a fresh session
stop-qa
run-qa
```

## check-test-result Usage

`check-test-result` prints the content of `$AGENT_PATH/outputs/test-results.json`, or reports the current run status if a test is still in progress.

```bash
check-test-result [-ap <agent-path>]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |

### Output
| Condition | Output |
| --- | --- |
| `run-qa` is currently active | A message indicating testing is in progress, including the orchestrator PID |
| `test-results.json` exists | The full JSON content of the results file |
| `test-results.json` missing, `agent.log` missing | `ℹ️  No test results found.` |
| `test-results.json` missing, `agent.log` exists | `ℹ️  No test results found.` followed by the full content of `agent.log` |

### Examples
```bash
# Check results after a run
check-test-result

# Check results using a custom agent path
check-test-result -ap /tmp/my-agent
```

---

## manage-global-constants Usage

`manage-global-constants` manages key/value entries in `$AGENT_PATH/instructions/global-context.json`. These values are injected into every test run as shared global variables (base URLs, tenant IDs, credentials, etc.).

```bash
manage-global-constants [-ap <agent-path>] <operation> [args]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |

### Operations
| Operation | Arguments | Description |
| --- | --- | --- |
| `list` | — | Display all current values, or a message if none are set |
| `set` | `KEY=value,...` | Set one or more key/value pairs (comma-delimited) |
| `delete` | `KEY,...` | Delete one or more keys by name (comma-delimited) |
| `clear` | — | Delete the entire context file |
| `help` / `h` | — | Show usage |

### Examples
```bash
# List all values
manage-global-constants list

# Set multiple values (quoted and unquoted)
manage-global-constants set BASE_URL="https://staging.example.com",TENANT=acme,SUPPORT_EMAIL=qa@example.com

# Overwrite an existing key
manage-global-constants set TENANT=newcorp

# Delete specific keys (unknown keys produce a warning, known keys are still deleted)
manage-global-constants delete BASE_URL,TENANT

# Remove all values (also deletes the file)
manage-global-constants clear

# Use a custom agent path
manage-global-constants -ap /tmp/my-agent set BASE_URL="https://local.example.com"
```

### Notes
- Key names are case-sensitive.
- Values may be quoted or unquoted.
- `set` creates the file and parent directories if they do not exist.
- Deleting all keys removes the file automatically.
- Unknown key names in `delete` print a warning but do not cause an error; any found keys are still deleted.

---

## manage-context-variables Usage

`manage-context-variables` manages key/value entries in `$AGENT_PATH/instructions/preset-context.json`. It has the same interface as `manage-global-constants` but targets the preset context file, which is used to supply per-run variable overrides on top of the global context.

```bash
manage-context-variables [-ap <agent-path>] <operation> [args]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |

### Operations
| Operation | Arguments | Description |
| --- | --- | --- |
| `list` | — | Display all current values, or a message if none are set |
| `set` | `KEY=value,...` | Set one or more key/value pairs (comma-delimited) |
| `delete` | `KEY,...` | Delete one or more keys by name (comma-delimited) |
| `clear` | — | Delete the entire context file |
| `help` / `h` | — | Show usage |

### Examples
```bash
# List all values
manage-context-variables list

# Set preset overrides
manage-context-variables set ENV=staging,FEATURE_FLAG=enabled

# Remove a specific key
manage-context-variables delete FEATURE_FLAG

# Clear all preset context
manage-context-variables clear

# Use a custom agent path
manage-context-variables -ap /tmp/my-agent list
```

### Notes
- Key names are case-sensitive.
- Values may be quoted or unquoted.
- `set` creates the file and parent directories if they do not exist.
- Deleting all keys removes the file automatically.
- Unknown key names in `delete` print a warning but do not cause an error; any found keys are still deleted.

---

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
Global variables shared across all tests are stored in `$AGENT_PATH/instructions/global-context.json`. The file contains a flat JSON object of string key/value pairs.

```json
{
    "REGISTER_URL": "http://host.docker.internal:8080/register",
    "LOGIN_URL": "http://host.docker.internal:8080/login",
    "EMAIL_URL": "http://host.docker.internal:8025"
}
```

Use `manage-global-constants` to read and update this file without editing JSON directly. See [manage-global-constants Usage](#manage-global-constants-usage).

### Preset Context
Per-run variable overrides are stored in `$AGENT_PATH/instructions/preset-context.json`, using the same JSON format as global context. These values can selectively override or extend the global context for a specific test run.

Use `manage-context-variables` to read and update this file. See [manage-context-variables Usage](#manage-context-variables-usage).

## Security & Permissions

### Filesystem Permission Matrix

| Path                                        | Owner:Group | Mode | `agentuser` access | Notes                                                     |
|---------------------------------------------| --- | --- | --- |-----------------------------------------------------------|
| `/agent`                                    | `agentuser:agentgroup` | varies | Mostly read/write in owned tree | Copied with `--chown=agentuser:agentgroup` in `Dockerfile` |
| `/agent/instructions`                       | `root:agentgroup` | `550` | Read + traverse, no write | Policy/config files mounted here are read-only at runtime |
| `/agent/tasks`                              | `root:agentgroup` | `550` | Read + traverse, no write | Task input files are read-only at runtime                 |
| `/agent/outputs`                            | `agentuser:agentgroup` | `770` | Full rwx | Agent writes logs and output artifacts here               |
| `/agent/bin`                                | `agentuser:agentgroup` | `770` | Full rwx | Writable bin directory for agent use                      |
| `/services/playwright`                      | `root:root` | `700` | No access | Playwright MCP service directory, root-only               |
| `/services/playwright/allowed-domains.yaml` | `root:root` | default file mode | Not accessible (parent dir `700`) | System fallback domain allowlist                          |
| `/services/email`                           | `root:root` | `700` | No access | Email MCP service directory, root-only                    |
| `/services/email/email-mcp.jar`             | `root:root` | default file mode | Not accessible (parent dir `700`) | Email MCP JAR, loaded by service script                   |
| `/usr/local/bin/run-qa`                     | `root:root` | `700` | Cannot execute | Container entrypoint script                               |
| `/usr/local/bin/stop-qa`                    | `root:root` | `700` | Cannot execute | Stops the tracked `run-qa` process tree                   |
| `/usr/local/bin/check-test-result`          | `root:root` | `700` | Cannot execute | Prints test results or in-progress status                 |
| `/usr/local/bin/playwright-mcp`             | `root:root` | `700` | Cannot execute | Playwright MCP launch script                              |
| `/usr/local/bin/email-mcp`                  | `root:root` | `700` | Cannot execute | Email MCP launch script                                   |
| `/usr/local/bin/config-agent`               | `root:root` | `700` | Cannot execute | Script to quickly config the agent                        |
| `/usr/local/bin/run-qa-lib`                 | `root:root` | `700` | Cannot execute | Shared library sourced by `run-qa`, `stop-qa`, `check-test-result` |
| `/usr/local/bin/manage-global-constants`    | `root:root` | `700` | Cannot execute | Manages entries in `global-context.json`                  |
| `/usr/local/bin/manage-context-variables`   | `root:root` | `700` | Cannot execute | Manages entries in `preset-context.json`                  |
| `/etc/profile.d/container_env.sh`           | `root:root` | `644` | Read-only | Environment variables forwarded from root to `agentuser`  |

### Command Availability Matrix

| Command / Action           | Root | `agentuser` | Invocation path                                          |
|----------------------------| --- | --- |----------------------------------------------------------|
| `run-qa`                   | ✅ | ❌ | `/usr/local/bin/run-qa` (mode `700`)                     |
| `stop-qa`                  | ✅ | ❌ | `/usr/local/bin/stop-qa` (mode `700`)                    |
| `check-test-result`        | ✅ | ❌ | `/usr/local/bin/check-test-result` (mode `700`)          |
| `config-agent`             | ✅ | ❌ | `/usr/local/bin/config-agent` (mode `700`)               |
| `manage-global-constants`  | ✅ | ❌ | `/usr/local/bin/manage-global-constants` (mode `700`)    |
| `manage-context-variables` | ✅ | ❌ | `/usr/local/bin/manage-context-variables` (mode `700`)   |
| `playwright-mcp`           | ✅ | ❌ | Started by Supervisor (`supervisord.conf`)               |
| `email-mcp`                | ✅ | ❌ | Started by Supervisor (`supervisord.conf`)               |
| `supervisorctl start/stop` | ✅ | ❌ | Used inside `run-qa.sh`                                  |
| `node dist/index.cjs`      | ✅ | ✅ | `su - agentuser -c "cd /agent && node dist/index.cjs"`   |
| `node dist/dry-run.cjs`    | ✅ | ✅ | `su - agentuser -c "cd /agent && node dist/dry-run.cjs"` |

### Effective Runtime Permissions (Summary)

| Area | `agentuser` effective permission |
| --- | --- |
| Agent execution | Runs as non-root via `su - agentuser` |
| `/agent/instructions` policies | Read-only — cannot self-modify policy files |
| MCP service binaries/control | No direct execute or control |
| `/services/*` internals | No direct access |
| Output/log artifacts in `/agent/outputs` | Full write access |


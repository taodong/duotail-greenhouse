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
docker buildx create --driver docker-container --name multiplatform
docker buildx build --platform linux/amd64,linux/arm64 --ssh default="$SSH_AUTH_SOCK" -t taojdcn/duotail-waterwheel:latest --push --builder multiplatform .
```
build mac only image
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
Create multiple platform driver once, then use it for building multi-platform images
```bash
docker buildx create --driver docker-container --name multiplatform
```

```bash
docker buildx build --platform linux/amd64,linux/arm64 --ssh default="$SSH_AUTH_SOCK" -t taojdcn/duotail-waterwheel:latest --push --builder multiplatform .
```

### Multi-Platform Build with fresh agent source
```bash
export DOCKER_BUILDKIT=1

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --ssh default="$SSH_AUTH_SOCK" \
  --build-arg AGENT_CLONE_BUSTER="$(date +%s)" \
  -t taojdcn/duotail-waterwheel:latest \
  --builder multiplatform \
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

## run-qa-lib (internal shared library)

`run-qa-lib` is a shared bash library sourced by `run-qa`, `stop-qa`, `check-test-result`, and `get-failure-detail`. It is not intended to be invoked directly.

It consolidates logic that was previously duplicated across `run-qa` and `stop-qa`:

| Symbol | Description |
| --- | --- |
| `RUN_QA_PID_FILE` | Path to the orchestrator PID file (`/tmp/run-qa.pid`) |
| `RUN_QA_AGENT_PID_FILE` | Path to the agent subprocess PID file (`/tmp/run-qa.agent.pid`) |
| `RUN_QA_LOCK_FILE` | Path to the exclusive lock file (`/tmp/run-qa.lock`) |
| `terminate_pid_tree <pid>` | Recursively terminates a process and all its children |
| `is_run_qa_active` | Returns `0` if `run-qa` is running, `1` otherwise; sets `$RUN_QA_ACTIVE_PID` |

---

## file-upload-lib Usage

`file-upload-lib` reads stdin and saves it to an absolute target file path.

```bash
file-upload-lib <absolute-path>
```

### Options
| Option | Description |
| --- | --- |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- Creates missing parent directories automatically.
- Replaces existing files and prints a warning.
- Returns an error if path is missing/invalid or any I/O step fails.

### Examples
```bash
# Write a short string
printf 'hello\n' | file-upload-lib /tmp/demo.txt

# Write JSON from a file to a nested path
cat ./payload.json | file-upload-lib /tmp/data/payload.json

# Show help
file-upload-lib --help
```

---

## check-test-result Usage

`check-test-result` prints the `exit_condition` from `$AGENT_PATH/outputs/test-results.json`, or reports the current run status if a test is still in progress.

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
| `test-results.json` exists | The `exit_condition` value from the results file |
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

## get-failure-detail Usage

`get-failure-detail` prints a full diagnostic report for the first failed test found in `$AGENT_PATH/outputs/test-results.json`. If a test run is still in progress, it reports that instead.

```bash
get-failure-detail [-ap <agent-path>] [-d]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-d` | Include API log (`$AGENT_PATH/outputs/api-log.json`) at the end of the report |

### Output when a failed test is found

Each section is printed in order. Missing files are reported inline and do not abort the output.

| Section | Source |
| --- | --- |
| **Failed Test Summary** | The failed test JSON object from `test-results.json` |
| **Test Detail** | `$AGENT_PATH/tasks/<test-file>` |
| **Test Steps** | `$AGENT_PATH/outputs/<test-file-stem>_log.json` |
| **Test Context** | `$AGENT_PATH/outputs/test-context.json` |
| **Agent Log** | `$AGENT_PATH/outputs/agent.log` |
| **API Log** _(only with `-d`, only if file exists)_ | `$AGENT_PATH/outputs/api-log.json` |

### Output when no failure

| Condition | Output |
| --- | --- |
| `run-qa` is currently active | A message indicating testing is in progress, including the orchestrator PID |
| `test-results.json` missing, `agent.log` missing | `ℹ️  No test results found.` |
| `test-results.json` missing, `agent.log` exists | `ℹ️  No test results found.` followed by the full content of `agent.log` |
| `test-results.json` exists, no failed tests | `✅ No failed tests found in test results.` |

### Examples
```bash
# Check first failure after a run
get-failure-detail

# Include API log in the report
get-failure-detail -d

# Use a custom agent path
get-failure-detail -ap /tmp/my-agent

# Custom agent path with API log
get-failure-detail -ap /tmp/my-agent -d
```

---

## manage-global-constants Usage

`manage-global-constants` manages key/value entries in `$AGENT_PATH/instructions/global-context.json`. These values are injected into every test run as shared global variables (base URLs, tenant IDs, credentials, etc.).
It also supports dotted keys for nested JSON objects (for example, `user.username=qa_user` becomes `{ "user": { "username": "qa_user" } }`).

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

# Set nested values at the root
manage-global-constants set user.username=qa_user,user.password=secret

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
- Dotted keys create nested objects.
- Unknown key names in `delete` print a warning but do not cause an error; any found keys are still deleted.

---

## manage-test-files Usage

`manage-test-files` manages markdown task files in `$AGENT_PATH/tasks`.

```bash
manage-test-files [-ap <agent-path>] <operation> [args]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |

### Operations
| Operation | Arguments | Description |
| --- | --- | --- |
| `list` | — | List `.md` task files with 1-based indexes |
| `add` | `path1,path2,...` | Add markdown files from file paths and direct directory children; non-markdown files are ignored |
| `delete` | `selector1,selector2,...` | Delete by 1-based index or exact filename (basename only), best effort |
| `clear` | — | Delete all markdown task files under `$AGENT_PATH/tasks` |
| `help` / `h` | — | Show usage |

### Examples
```bash
# List current markdown test files
manage-test-files list

# Add two markdown files
manage-test-files add ./temp/instructions/test-a.md,./temp/instructions/test-b.md

# Add all direct markdown files from a directory (subdirectories are ignored)
manage-test-files add ./temp/instructions

# Delete by index
manage-test-files delete 1,3

# Delete by filename and index in one call
manage-test-files delete login-flow.md,2

# Clear all markdown task files
manage-test-files clear

# Use a custom agent path
manage-test-files -ap /tmp/my-agent add ./temp/instructions
```

### Notes
- Only `.md` files are listed and managed.
- `add` overwrites existing files with the same destination basename and prints aggregated overwrite warnings.
- Directory import includes only direct child files, not subdirectories.
- `delete` is best effort: invalid selectors print warnings while valid selectors are still deleted.

---

## preset-context Usage

`preset-context` manages `$AGENT_PATH/instructions/preset-context.json` through two mutually exclusive families:

- `variables` manages runtime values under `data`
- `flow` lists, imports, or clears the stored `flow` array

The two families are exclusive in a single command call. Mixed invocations are rejected.

```bash
preset-context [-ap <agent-path>] <family> [args]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |

### `variables` operations
| Operation | Arguments | Description |
| --- | --- | --- |
| `list` | — | Display all current values, or a message if none are set |
| `set` | `KEY=value,...` | Set one or more key/value pairs under `data` (comma-delimited) |
| `delete` | `KEY,...` | Delete one or more keys from `data` (supports dotted paths) |
| `clear` | — | Clear `data`; keep `flow` if present |
| `help` / `h` | — | Show usage |

### `flow` usage
| Family | Arguments | Description |
| --- | --- | --- |
| `flow` | `list` | Display the current flow entries, or a message if none are set |
| `flow` | `flow.json` | Import a file whose top-level object contains `flow`; extra properties are ignored and `.flow` is replaced |
| `flow` | `clear` | Clear existing `flow` entries; preserve `data` |

### Examples
```bash
# List all values
preset-context variables list

# Set preset overrides (stored under data)
preset-context variables set username=admin,password=123456789

# Set nested values with dotted keys
preset-context variables set user.username=admin,user.password=123456789

# Remove keys from data (supports dotted keys)
preset-context variables delete username,user.password

# Clear preset data (flow is preserved if present)
preset-context variables clear

# Import flow from a JSON file
preset-context flow ./instructions/preset-flow.json

# Clear flow entries while preserving data
preset-context flow clear

# List current flow entries
preset-context flow list

# Use a custom agent path
preset-context -ap /tmp/my-agent variables list

# Mixed family calls are rejected
preset-context flow ./instructions/preset-flow.json variables set foo=bar
```

The imported file may contain extra top-level metadata; only the `flow` array is used.

```json
{
  "flow": [
    { "file": "login.md", "node": 1 }
  ],
  "data": { "ignored": true },
  "notes": "also ignored"
}
```

### Notes
- Key names are case-sensitive.
- Values may be quoted or unquoted.
- `set` creates the file and parent directories if they do not exist.
- In `preset-context.json`, managed values are stored under `data`.
- Dotted keys are consolidated into nested objects (for example: `user.username=abc` -> `{"data":{"user":{"username":"abc"}}}`).
- `flow` accepts `list`, `clear`, or a file path.
- When `list` is used, flow entries in `preset-context.json` are printed; if none are set, a message is shown.
- When a file path is provided, the imported JSON must contain a top-level `flow` array; extra properties are ignored.
- `variables` and `flow` are mutually exclusive in a single call.
- The file is deleted only when both `data` and `flow` are missing/empty.
- Unknown key names in `delete` print a warning but do not cause an error; any found keys are still deleted.

---

## config-ai-provider Usage

`config-ai-provider` applies an AI provider mode and model without interactive prompts.

```bash
config-ai-provider --provider <provider> --model <model> --mode <default|efficiency> [-ap <agent-path>] [-cp <config-helpers-path>]
```

### Options
| Option | Description |
| --- | --- |
| `--provider <value>` | Provider value written directly to `AI_PROVIDER` (for example: `openai`) |
| `--model <value>` | Model value written directly to `AI_MODEL` |
| `--mode <value>` | Mode selector: `default` -> `<provider>-default.env`, `efficiency` -> `<provider>-token-efficiency.env` |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-cp <path>` | Override the config helpers path (default: `/config-helpers`) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior

- Uses the same mode-file update flow as `config-agent` option `1`.
- Respects provider locking: once a provider is configured, switching to a different provider requires a new container.
- Does **not** prompt for Gemma `AI_BASE_URL`.
- Does **not** enable the DeepSeek Chinese system prompt.
- Does **not** append Gemma extra instructions.

### Examples

```bash
# Apply OpenAI default mode with an explicit model
config-ai-provider --provider openai --model gpt-5.4 --mode default

# Apply Anthropic efficiency mode against a local/dev agent path
config-ai-provider \
  --provider anthropic \
  --model claude-sonnet-4-5 \
  --mode efficiency \
  -ap /tmp/my-agent \
  -cp /tmp/config-helpers
```

---

## display-ai-config Usage

`display-ai-config` prints effective AI runtime settings as JSON.

```bash
display-ai-config [-ap <agent-path>]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Output

Returns a JSON object with exactly these keys:

- `aiProvider`
- `aiModel`
- `tokenMode`

Lookup order per key:

1. Environment variable
2. `default` in `$AGENT_PATH/config/agent-config.json` under `env-params[]`

Key mapping:

- `aiProvider` -> `AI_PROVIDER`
- `aiModel` -> `AI_MODEL`
- `tokenMode` -> `CONTEXT_COMPRESSION`

`tokenMode` mapping behavior:

- `CONTEXT_COMPRESSION=false` (case-insensitive) -> `default`
- Any other non-empty value -> `efficiency`
- No value from env or config -> empty string

### Examples

```bash
# Show effective AI settings from /agent
display-ai-config

# Override path for local/dev testing
display-ai-config -ap /tmp/my-agent

# Show help
display-ai-config --help
```

---

## reset-test-config Usage

`reset-test-config` deletes test task files and/or instruction files to return the agent to a clean state.

```bash
reset-test-config [-ap <agent-path>] [-t] [-i]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-t` | Delete all `.md` files under `$AGENT_PATH/tasks` |
| `-i` | Delete all files under `$AGENT_PATH/instructions` except `email-permissions.yaml` |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- When neither `-t` nor `-i` is provided, **both** operations are performed.
- `email-permissions.yaml` is always preserved when resetting instructions.
- Missing directories are reported but do not cause an error.

### Examples
```bash
# Reset both tasks and instructions
reset-test-config

# Reset task files only
reset-test-config -t

# Reset instruction files only
reset-test-config -i

# Reset both explicitly
reset-test-config -t -i

# Use a custom agent path
reset-test-config -ap /tmp/my-agent -t
```

---

## set-domain-permission Usage

`set-domain-permission` generates the Playwright MCP domain allowlist at `$AGENT_PATH/instructions/allowed-domains.yaml` from a comma-delimited list of domains. Each domain becomes one entry under the `allowed` array.

```bash
set-domain-permission [-ap <agent-path>] [-l] <domain1,domain2,...>
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-l` | Rewrite every `localhost` in the domains to `host.docker.internal` (useful when targeting a local dev server from inside Docker) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- Domains are separated by commas. Quote any entry containing shell-special characters, e.g. `"https://*.wikipedia.org"`.
- Leading and trailing whitespace around each entry is trimmed.
- Empty entries are ignored.
- The target `allowed-domains.yaml` is overwritten each run.

### Examples
```bash
# Generate allowed-domains.yaml from a list of domains
set-domain-permission https://www.google.com,"https://*.wikipedia.org","http://localhost:8080"
# Produces:
# allowed:
#   - https://www.google.com
#   - https://*.wikipedia.org
#   - http://localhost:8080

# Rewrite localhost to host.docker.internal with -l
set-domain-permission -l https://www.google.com,"https://*.wikipedia.org","http://localhost:8080"
# Produces:
# allowed:
#   - https://www.google.com
#   - https://*.wikipedia.org
#   - http://host.docker.internal:8080

# Use a custom agent path
set-domain-permission -ap /tmp/my-agent -l "http://localhost:8025"
```

---

## upload-instruction-file Usage

`upload-instruction-file` creates or replaces a file under `$AGENT_PATH/instructions` using content read from stdin. The `<filename>` argument is appended to `$AGENT_PATH/instructions` to form the full target path (it is passed to `file-upload-lib`). This is a convenient way to push instruction/config files (e.g. `allowed-domains.yaml`, `email-permissions.yaml`, `extra-instructions.md`) into the agent without editing files in place.

```bash
upload-instruction-file [-ap <agent-path>] <filename>
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- Content is read from stdin and written to `$AGENT_PATH/instructions/<filename>`.
- Missing parent directories are created automatically (e.g. a nested `<filename>`).
- An existing file is replaced, and a `WARNING` is printed to stderr when it is.

### Examples
```bash
# Create or replace allowed-domains.yaml from stdin
printf 'allowed:\n  - http://host.docker.internal:8080\n' | \
  upload-instruction-file allowed-domains.yaml

# Pipe a local file into the instructions folder
cat ./extra-instructions.md | upload-instruction-file extra-instructions.md

# Use a custom agent path
cat ./email-permissions.yaml | upload-instruction-file -ap /tmp/my-agent email-permissions.yaml
```

---

## upload-test-task Usage

`upload-test-task` creates or replaces a Markdown test task under `$AGENT_PATH/tasks` using content read from stdin. The `<filename.md>` argument is appended to `$AGENT_PATH/tasks` to form the full target path (it is passed to `file-upload-lib`). Only Markdown files are accepted — the filename must end with `.md`.

```bash
upload-test-task [-ap <agent-path>] <filename.md>
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- Content is read from stdin and written to `$AGENT_PATH/tasks/<filename.md>`.
- The filename must end with `.md`, otherwise the command fails.
- Missing parent directories are created automatically (e.g. a nested `<filename.md>`).
- An existing file is replaced, and a `WARNING` is printed to stderr when it is.

### Examples
```bash
# Create or replace a test task from stdin
printf '# Login test\n' | upload-test-task login.md

# Pipe a local file into the tasks folder
cat ./checkout.md | upload-test-task checkout.md

# Use a custom agent path
cat ./signup.md | upload-test-task -ap /tmp/my-agent signup.md
```

---

## enable-test-on-host Usage

`enable-test-on-host` non-interactively enables host testing, mirroring the **Enable host testing** action in `config-agent` (`enable_host_testing`):

- Appends the host-testing block from `extra-local.md` (under config-helpers) to `$AGENT_PATH/instructions/extra-instructions.md`.
- Records the `host-testing` entry in the agent config status file.
- Rewrites `localhost` → `host.docker.internal` in `$AGENT_PATH/instructions/allowed-domains.yaml`.

In addition, if `$AGENT_PATH/instructions/global-context.json` exists, every `localhost` value in it is rewritten to `host.docker.internal`.

```bash
enable-test-on-host [-ap <agent-path>] [-cp <config-helpers-path>]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-cp <path>` | Override the config-helpers path (default: `/config-helpers`) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- Re-running is idempotent: the host-testing block and status entry are not duplicated if host testing is already enabled.
- Fails if `extra-local.md` is not found under the config-helpers path.
- `allowed-domains.yaml` and `global-context.json` are only rewritten if they exist and contain `localhost`.

### Examples
```bash
# Enable host testing with default paths
enable-test-on-host

# Use custom agent and config-helpers paths
enable-test-on-host -ap /tmp/my-agent -cp /tmp/config-helpers
```

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

Use `set-domain-permission` to generate this file from a comma-delimited domain list instead of editing YAML directly. See [set-domain-permission Usage](#set-domain-permission-usage).

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
Global variables shared across all tests are stored in `$AGENT_PATH/instructions/global-context.json`. The file contains a JSON object that supports nested keys via dotted notation.

```json
{
    "REGISTER_URL": "http://host.docker.internal:8080/register",
    "LOGIN_URL": "http://host.docker.internal:8080/login",
    "EMAIL_URL": "http://host.docker.internal:8025"
}
```

Use `manage-global-constants` to read and update this file without editing JSON directly. See [manage-global-constants Usage](#manage-global-constants-usage).

### Preset Context
Per-run overrides are stored in `$AGENT_PATH/instructions/preset-context.json` using this schema:

```json
{
    "data": {
        "baseUrl": "http://host.docker.internal:8080",
        "user": {
            "username": "qa_user"
        }
    },
    "flow": []
}
```

`preset-context variables` manages only the `data` section.
`preset-context flow` imports a file-path wrapper object and replaces only the `flow` section, or `preset-context flow clear` clears `flow`.
`manage-global-constants` behavior is unchanged except that it now also supports dotted keys for nested JSON in `global-context.json`.

Use `preset-context` to read and update this file. See [preset-context Usage](#preset-context-usage).

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
| `/usr/local/bin/get-failure-detail`         | `root:root` | `700` | Cannot execute | Prints full diagnostic report for the first failed test   |
| `/usr/local/bin/playwright-mcp`             | `root:root` | `700` | Cannot execute | Playwright MCP launch script                              |
| `/usr/local/bin/email-mcp`                  | `root:root` | `700` | Cannot execute | Email MCP launch script                                   |
| `/usr/local/bin/config-agent`               | `root:root` | `700` | Cannot execute | Script to quickly config the agent                        |
| `/usr/local/bin/config-ai-provider`         | `root:root` | `700` | Cannot execute | Non-interactively applies provider/model/mode settings    |
| `/usr/local/bin/run-qa-lib`                 | `root:root` | `700` | Cannot execute | Shared library sourced by `run-qa`, `stop-qa`, `check-test-result` |
| `/usr/local/bin/file-upload-lib`            | `root:root` | `700` | Cannot execute | Saves stdin content to a target file path |
| `/usr/local/bin/manage-global-constants`    | `root:root` | `700` | Cannot execute | Manages entries in `global-context.json`                  |
| `/usr/local/bin/manage-test-files`          | `root:root` | `700` | Cannot execute | Manages markdown test files in `/agent/tasks`             |
| `/usr/local/bin/preset-context`             | `root:root` | `700` | Cannot execute | Manages entries in `preset-context.json`                  |
| `/usr/local/bin/display-ai-config`          | `root:root` | `700` | Cannot execute | Prints effective AI provider/model/token mode as JSON     |
| `/usr/local/bin/reset-test-config`          | `root:root` | `700` | Cannot execute | Deletes task `.md` files and/or instruction files         |
| `/etc/profile.d/container_env.sh`           | `root:root` | `644` | Read-only | Environment variables forwarded from root to `agentuser`  |

### Command Availability Matrix

| Command / Action           | Root | `agentuser` | Invocation path                                          |
|----------------------------| --- | --- |----------------------------------------------------------|
| `run-qa`                   | ✅ | ❌ | `/usr/local/bin/run-qa` (mode `700`)                     |
| `stop-qa`                  | ✅ | ❌ | `/usr/local/bin/stop-qa` (mode `700`)                    |
| `check-test-result`        | ✅ | ❌ | `/usr/local/bin/check-test-result` (mode `700`)          |
| `get-failure-detail`       | ✅ | ❌ | `/usr/local/bin/get-failure-detail` (mode `700`)         |
| `config-agent`             | ✅ | ❌ | `/usr/local/bin/config-agent` (mode `700`)               |
| `config-ai-provider`       | ✅ | ❌ | `/usr/local/bin/config-ai-provider` (mode `700`)         |
| `file-upload-lib`          | ✅ | ❌ | `/usr/local/bin/file-upload-lib` (mode `700`)            |
| `manage-global-constants`  | ✅ | ❌ | `/usr/local/bin/manage-global-constants` (mode `700`)    |
| `manage-test-files`        | ✅ | ❌ | `/usr/local/bin/manage-test-files` (mode `700`)          |
| `preset-context`            | ✅ | ❌ | `/usr/local/bin/preset-context` (mode `700`)              |
| `display-ai-config`        | ✅ | ❌ | `/usr/local/bin/display-ai-config` (mode `700`)          |
| `reset-test-config`        | ✅ | ❌ | `/usr/local/bin/reset-test-config` (mode `700`)          |
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


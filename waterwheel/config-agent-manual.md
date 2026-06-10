# config-agent User Manual

`config-agent` is an interactive shell script for configuring the Waterwheel agent before a test run. It manages AI provider settings, browser domain permissions, host testing mode, and writes all configuration to the files the agent reads at startup.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Usage](#usage)
3. [Main Menu](#main-menu)
4. [Option 1 — AI Provider Mode](#option-1--ai-provider-mode)
   - [Selecting a Mode](#selecting-a-mode)
   - [Entering the AI Model](#entering-the-ai-model)
   - [Gemma: Ollama Base URL](#gemma-ollama-base-url)
   - [DeepSeek: Chinese System Prompt](#deepseek-chinese-system-prompt)
   - [Manual Customized](#manual-customized)
   - [Switching Modes](#switching-modes)
5. [Option 2 — Config Domain Permissions](#option-2--config-domain-permissions)
6. [Option 3 — Test Web App on Host](#option-3--test-web-app-on-host)
7. [Exit Warning](#exit-warning)
8. [Files Modified](#files-modified)
9. [State Tracking](#state-tracking)
10. [Local Testing](#local-testing)
11. [Adding a New Mode](#adding-a-new-mode)

---

## Prerequisites

Inside the container the script is available at `/usr/local/bin/config-agent` and runs as `root`.

The following files must exist before the script is run:

| File | Purpose |
|---|---|
| `/agent/config/agent-config.json` | Agent runtime configuration updated by option 1. Created by the agent build stage. If missing, option 1 will show an error and prompt you to pull a new image. |
| `/config-helpers/modes/*.env` | Predefined AI provider mode profiles. |
| `/config-helpers/extra-local.md` | Extra instruction content appended when host testing is enabled. |
| `/config-helpers/extra-gemma.md` | Extra instruction content appended when a Gemma mode is applied. |
| `/config-helpers/system-prompt-cn.md` | Chinese system prompt used when DeepSeek CN prompt is enabled. |
| `/config-helpers/system-prompt-default.md` | Default system prompt restored when CN prompt is disabled. |

---

## Usage

**Inside the container:**
```
config-agent
```

**Local testing** (pointing at a local directory):
```
config-agent -ap <agent-path> -cp <config-helpers-path>
```

### Options

| Flag | Default | Description |
|---|---|---|
| `-ap`, `--agent-path` | `/agent` | Root path of the agent directory. The script looks for `instructions/`, `config/` etc. under this path. |
| `-cp`, `--config-helpers-path` | `/config-helpers` | Path to the config helpers directory containing mode files, extra instructions, and system prompts. |

**Example — local test run:**
```
./config-agent.sh \
  -ap ./waterwheel/files/bootstrap \
  -cp ./waterwheel/files/bootstrap
```

---

## Main Menu

```
========================================
  Waterwheel Agent Configuration
========================================

  Select an item to configure:

  1. AI provider mode [not set]
  2. Config domain permissions
  3. Test web app on host [disabled]
  0. Exit

----------------------------------------
  Choice:
```

The current state of option 1 (active mode name) and option 3 (enabled/disabled) is shown inline. Enter the number and press Enter.

---

## Option 1 — AI Provider Mode

Selects the AI provider and model the agent will use. Writes the chosen settings to `/agent/config/agent-config.json`.

### Selecting a Mode

The menu lists all `.env` files found in the `modes/` directory, sorted alphabetically, plus a **Manual customized** option at the end.

```
=== AI Provider Mode [not set] ===

  Select a mode:

  1) Anthropic Default Mode
  2) Anthropic Token Efficiency Mode
  3) DeepSeek Default Mode
  4) DeepSeek Token Efficiency Mode
  5) Gemini Default Mode
  6) Gemini Token Efficiency Mode
  7) Gemma 4 Default Mode
  8) Open AI Default Mode
  9) Open AI Token Efficiency Mode
  10) Manual customized

----------------------------------------
  0) Back
----------------------------------------
  Choice:
```

If a mode file contains a `# Notes:` comment, its text is displayed before the model prompt:

```
  Notes: Only gemini-2.5-flash and gemini-2.5-pro are currently supported
```

### Entering the AI Model

Every mode requires you to enter an AI model name. If the mode file defines a `# Recommendation:` value it is shown as a default — press Enter to accept it, or type your own value.

```
  Enter AI model [recommended: claude-sonnet-4-6]:
```

### Gemma: Ollama Base URL

When a Gemma mode is selected (provider `gemma`), you are also prompted for the Ollama server base URL. This value is written to `AI_BASE_URL` in `agent-config.json`.

```
  Enter Ollama base URL (e.g. http://host.docker.internal:11434):
```

If Ollama runs on the host machine, use `http://host.docker.internal:<port>`.

After confirmation, the content of `extra-gemma.md` is appended to `/agent/instructions/extra-instruction.md` inside a `<!-- gemma-start -->` / `<!-- gemma-end -->` marker block, and `gemma` is recorded in `agent-config-status.yaml` under `extra-instructions`.

### DeepSeek: Chinese System Prompt

When a DeepSeek mode is selected (provider `deepseek`), you are asked whether to use the Chinese system prompt:

```
  Use Chinese system prompt? [y/N]:
```

- **y** — overwrites `/agent/config/system.prompt.md` with the content of `system-prompt-cn.md` and sets `system-prompt: cn` in `agent-config-status.yaml`.
- **n / Enter** — if the Chinese prompt was previously active it is disabled and `system.prompt.md` is restored from `system-prompt-default.md`.

### Manual Customized

Choosing **Manual customized** tells the script that you have configured the required environment variables (`AI_PROVIDER`, `AI_MODEL`, `AI_API_KEY`) yourself. The script records `provider-mode: manual` in `agent-config-status.yaml` and suppresses the exit warning. No changes are made to `agent-config.json`.

### Switching Modes

When you apply a different mode, the script automatically cleans up the previous mode's side effects before applying the new one:

| Previous state | Action taken on switch |
|---|---|
| Gemma extra instruction active | Removes the `<!-- gemma-start/end -->` block from `extra-instruction.md` and removes `gemma` from `agent-config-status.yaml`. |
| Chinese system prompt active | Restores `system.prompt.md` from `system-prompt-default.md` and removes `system-prompt: cn` from `agent-config-status.yaml`. |

### Applied Settings

After a successful apply, the script prints every `KEY=VALUE` pair written to `agent-config.json`:

```
  Mode set to: Anthropic Token Efficiency Mode (model: claude-sonnet-4-6)

  Applied settings:
    AI_PROVIDER=anthropic
    AI_MAX_TOKENS=8192
    MAX_SNAPSHOTS_HISTORY=0
    CONTEXT_COMPRESSION=true
    COMPRESSION_THRESHOLD_MIN=2500
    COMPRESSION_THRESHOLD_LEAP=500
    LARGE_CONTENT_THRESHOLD=10000
    RATE_LIMIT_RETRY=2
    MAX_ITERATIONS=100
    MAXIMUM_RESTRICTED_TOOL_USAGE=3
    AI_MODEL=claude-sonnet-4-6
```

For Gemma, `AI_BASE_URL` is included at the end if a value was entered.

---

## Option 2 — Config Domain Permissions

Manages the browser domain allowlist in `/agent/instructions/allowed-domains.yaml`. The agent's Playwright MCP service blocks navigation to any domain not on this list.

```
=== Config Domain Permissions ===

  Current allowed domains:
    1. https://www.example.com
    2. https://staging.example.com

----------------------------------------
  1) Add domain
  2) Delete domain
  3) Save changes
  0) Back
----------------------------------------
```

- **1) Add domain** — enter a full URL (e.g. `https://example.com`). Changes are held in memory until saved.
- **2) Delete domain** — enter the number of the domain to remove.
- **3) Save changes** — writes the current list to `allowed-domains.yaml`. If all domains have been deleted, the file is removed and only the empty page (`about:blank`) will be accessible.
- **0) Back** — if there are unsaved changes you are asked to confirm before discarding them.

> **Warning:** If you add a domain containing `localhost`, the script displays a reminder that `localhost` is not reachable inside the container. Use `host.docker.internal` instead and enable **Test web app on host** (option 3).

---

## Option 3 — Test Web App on Host

Enables or disables the host testing mode, which allows the agent to reach a web server running on the host machine.

```
=== Test Web App on Host [disabled] ===

  Host testing is currently disabled.

----------------------------------------
  1) Enable host testing
  0) Back
----------------------------------------
```

### Enabling

1. Appends the content of `extra-local.md` to `/agent/instructions/extra-instruction.md` inside a `<!-- host-testing-start -->` / `<!-- host-testing-end -->` marker block. This injects a URL-rewriting rule that replaces `localhost` with `host.docker.internal` in all URLs the agent encounters.
2. If `allowed-domains.yaml` contains any `localhost` entries, they are rewritten to `host.docker.internal`.
3. Records `host-testing` under `extra-instructions` in `agent-config-status.yaml`.

### Disabling

1. Removes the `<!-- host-testing-start/end -->` block from `extra-instruction.md`. If no other extra-instruction blocks remain, `extra-instruction.md` is deleted.
2. Rewrites `host.docker.internal` back to `localhost` in `allowed-domains.yaml`.
3. Removes `host-testing` from `agent-config-status.yaml`.

---

## Exit Warning

When you choose **0. Exit**, the script checks whether the agent has the minimum required configuration. If no AI provider mode has been set **and** neither `AI_MODEL` nor `AI_API_KEY` is present as an environment variable, the following warning is shown:

```
  ⚠  Warning: No AI provider mode is configured.
     Select option 1 to configure, or ensure AI_PROVIDER, AI_MODEL,
     and AI_API_KEY are set as environment variables before running the agent.

  Exit anyway? [y/N]:
```

The warning is suppressed when:
- A mode has been applied via option 1 (including **Manual customized**).
- `AI_MODEL` and `AI_API_KEY` are both set in the environment.

---

## Files Modified

| File | Modified by |
|---|---|
| `/agent/config/agent-config.json` | Option 1 — updates `default` values of `env-params` entries |
| `/agent/config/system.prompt.md` | Option 1 (DeepSeek) — replaced with CN or default content |
| `/agent/instructions/allowed-domains.yaml` | Option 2, Option 3 |
| `/agent/instructions/extra-instruction.md` | Option 1 (Gemma), Option 3 |
| `/config-helpers/agent-config-status.yaml` | All options — tracks current configuration state |

---

## State Tracking

All persistent state is written to `/config-helpers/agent-config-status.yaml`. This file is the single source of truth for what has been configured.

**Example with all features active:**

```yaml
extra-instructions:
  - host-testing
  - gemma
provider-mode: gemma-default
system-prompt: cn
```

| Key | Values | Meaning |
|---|---|---|
| `extra-instructions` | array of strings | Active extra-instruction blocks appended to `extra-instruction.md`. Currently used values: `host-testing`, `gemma`. |
| `provider-mode` | mode slug or `manual` | The currently applied AI provider mode. Slug matches the `.env` filename without the extension (e.g. `anthropic-default`). |
| `system-prompt` | `cn` | Set when the Chinese system prompt is active. Absent when the default prompt is in use. |

The file is created automatically on first write and deleted if all `extra-instructions` entries are removed and no other keys remain.

---

## Local Testing

To test the script against a local directory without a running container:

```bash
# Create a local agent directory structure
mkdir -p ./local-agent/config ./local-agent/instructions

# Copy a reference agent-config.json into it
cp ./waterwheel/files/bootstrap/default-agent-config.json \
   ./local-agent/config/agent-config.json

# Run the script pointing at local paths
./waterwheel/files/scripts/config-agent.sh \
  -ap ./local-agent \
  -cp ./waterwheel/files/bootstrap
```

`update-agent-config.sh` is resolved automatically: the script first looks for it in the same directory as `config-agent.sh`, then falls back to `update-agent-config` on `PATH`.

---

## Adding a New Mode

1. Create a new `.env` file in `waterwheel/files/bootstrap/modes/`.
2. Use the following header comments (all optional except `label`):

   ```bash
   # label: My Provider Default Mode
   # Recommendation: my-model-name
   # Notes: Any constraint or guidance shown to the user at selection time.
   ```

3. Add `KEY=VALUE` lines for every `env-params` entry in `agent-config.json` you want to override. Unknown keys are silently ignored.
4. Rebuild the Docker image — the `COPY` instruction in the Dockerfile copies the entire `modes/` directory into `/config-helpers/modes/` at build time.

**Special provider handling** is triggered by the `AI_PROVIDER` value in the mode file:

| `AI_PROVIDER` value | Extra behaviour |
|---|---|
| `gemma` | Prompts for `AI_BASE_URL`; appends `extra-gemma.md` block to `extra-instruction.md`. |
| `deepseek` | Prompts whether to use the Chinese system prompt. |

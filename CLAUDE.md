# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains Docker images for the **Duotail AI agent** — specifically the **Waterwheel** web testing agent. Waterwheel is an AI-driven QA agent that can automate browser interactions, form submissions, and email-based test flows inside an isolated container.

## Build Commands

All Docker builds require SSH agent forwarding (the agent source is cloned from a private repo during build):

```bash
# Local build (single platform)
cd waterwheel
DOCKER_BUILDKIT=1 docker build --ssh default="$SSH_AUTH_SOCK" \
  -t taojdcn/duotail-waterwheel:latest-mac .

# Force re-clone of agent source (bust the agent layer cache)
docker build --build-arg AGENT_CLONE_BUSTER="$(date +%s)" \
  --ssh default="$SSH_AUTH_SOCK" -t taojdcn/duotail-waterwheel:latest-mac .

# Multi-platform build and push
docker buildx build --platform linux/amd64,linux/arm64 \
  --ssh default="$SSH_AUTH_SOCK" -t taojdcn/duotail-waterwheel:latest --push .
```

## Running the Container

```bash
# Normal run (agent executes test instructions)
docker run -it taojdcn/duotail-waterwheel:latest-mac

# Dry-run mode (validation only, no actual execution)
docker run -it taojdcn/duotail-waterwheel:latest-mac run-qa --dry-run
```

### Key Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `ENABLE_PLAYWRIGHT_MCP` | `true` | Toggle browser automation service |
| `ENABLE_EMAIL_MCP` | `true` | Toggle email MCP service |
| `FIREWALL_DEBUG` | `false` | Verbose Playwright logging |
| `GLOBAL_CONTEXT` | — | Path to JSON file with global test variables |
| `PLAYWRIGHT_MCP_VERSION` | `0.0.74` | MCP version (must match installed) |
| `MAIL_HOST`, `MAIL_PORT`, `MAILHOG_URL` | — | Override email MCP settings |
| `JAVA_OPTS` | `-Xmx256m` | JVM memory for Email MCP |

## Architecture

### Multi-Stage Docker Build

The `waterwheel/Dockerfile` has three build stages:
1. **system-deps** — Base image (Playwright), Java 25 (Temurin), npm, Playwright MCP, Email MCP JAR
2. **agent-builder** — Clones private agent repo, compiles TypeScript to `.cjs`, strips source, obfuscates output
3. **final** — Assembles runtime image, sets up security permissions and Supervisor

### Three-Tier Service Model

```
┌─────────────────────────────────────────┐
│  System Layer (root)                    │
│  ├── Xvfb :99 (virtual display)         │
│  ├── Playwright MCP :3000               │
│  └── Email MCP :3002                   │
├─────────────────────────────────────────┤
│  Agent Layer (agentuser:2000)           │
│  └── Node.js agent (dist/index.cjs)    │
├─────────────────────────────────────────┤
│  Configuration Layer                    │
│  ├── /agent/instructions/ (read-only)  │
│  └── /agent/outputs/ (writable)        │
└─────────────────────────────────────────┘
```

- The agent communicates with both MCP services via HTTP on localhost
- `run-qa.sh` orchestrates startup: launches Xvfb → waits for MCPs → switches to agentuser → runs agent
- Supervisor manages service lifecycle with auto-restart

### Security Model

| Path | Owner | Permissions | Purpose |
|---|---|---|---|
| `/agent/instructions/` | root:agentgroup | 2550 | Read-only policies and configs |
| `/agent/skills/` | root:agentgroup | 2550 | Read-only skill files and configs |
| `/agent/outputs/` | agentuser:agentgroup | 770 | Agent writes logs/artifacts here |
| `/agent/bin/` | agentuser:agentgroup | 770 | Agent working directory |
| `/services/playwright/` | root:root | 700 | Inaccessible to agentuser |
| `/services/email/` | root:root | 700 | Inaccessible to agentuser |

### Bootstrap / Runtime Configuration

Files mounted at `/agent/instructions/` control agent behavior:

- **`global-context.json`** — Shared test variables (base URLs, credentials, etc.)
- **`allowed-domains.yaml`** — Playwright domain allowlist; agent cannot navigate outside these origins
- **`email-permissions.yaml`** — Controls sender/recipient allowlist for email MCP
- **`extra-instructions.md`** — Injected into every test run (used for URL rewriting: `localhost` → `host.docker.internal`)
- test instruction `.md` files — Agent test cases (the agent's system prompt lives separately at `/agent/config/system.prompt.md`)

The `waterwheel/files/bootstrap/` directory contains example/default versions of all these files.

### URL Rewriting

When running tests against a local development server from inside Docker, `extra-instructions.md` instructs the agent to replace `localhost` with `host.docker.internal` automatically.

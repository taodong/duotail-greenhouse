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

Only one `run-qa` process can run at a time, and it shares that single-instance lock with [`rerun-tests`](#rerun-tests-usage). If another `run-qa` or `rerun-tests` session is already active, the command exits and names the stop command for that session (`stop-qa` or `stop-rerun`).

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

## rerun-tests Usage

`rerun-tests` replays a chosen subset of tasks through the agent's rerun entry point
(`dist/rerun-qa.cjs`), seeded from a context checkpoint captured during the most recent full
`run-qa` run. It brings up the same services as `run-qa` (Xvfb, Playwright MCP, Email MCP).

```bash
rerun-tests
```

It takes no options.

### Prerequisites

1. **A completed `run-qa` run.** Every normal run writes a per-task context checkpoint to
   `/agent/outputs/checkpoints/<taskId>.json`. Those checkpoints are what a rerun seeds from,
   so a rerun is only meaningful after a full run has produced them.
2. **A rerun-config file** at `/agent/instructions/rerun-config.json` naming the task files to
   replay, in execution order. `rerun-tests` exits `1` before starting any service if it is
   missing.

```bash
generate-rerun-config -f test-2.md -f test-5.md \
  | upload-instruction-file rerun-config.json
```

[`generate-rerun-config`](#generate-rerun-config-usage) validates every task filename against
`/agent/tasks` and applies the agent's own `name` rules before emitting anything, so a mistake
fails there rather than after this command has started the display and the MCP services. Writing
the JSON by hand works too:

```bash
printf '{"flow":[{"file":"test-2.md"},{"file":"test-5.md"}]}' \
  | upload-instruction-file rerun-config.json
```

The file also accepts optional `name` and `data` properties (naming the output folder and
overriding context values respectively). See the "Checkpoint & Rerun" section of the agent
repo's `README.md` for the full semantics, including how the seed checkpoint is chosen and
why dependency checking is bypassed.

The config location is resolved from the `RERUN_CONFIG_PATH` agent parameter — process
environment first, then the `agent-config.json` default, then `./instructions/rerun-config.json`.
Relative paths resolve against `/agent`.

### Output handling

Unlike `run-qa`, **`rerun-tests` never cleans `/agent/outputs`** — it reads
`outputs/checkpoints/` and `outputs/test-results.json` from there. Each invocation writes to
its own `outputs/rerun-<name>/` (or auto-numbered `outputs/rerun-N/`) subfolder and leaves the
original run's results untouched.

Note that the next `run-qa` *does* clean `/agent/outputs`, clearing both the checkpoints and
any `outputs/rerun-*` folders. Checkpoints only ever belong to the most recent full run.

### Reading rerun results

A rerun folder holds the same filenames as a full run's `outputs/` — `test-results.json`,
`test-context.json`, `agent.log`, `api-log.json`, `<test-file-stem>_log.json` — written by the
same agent code, with the same JSON schema. Only `checkpoints/` is absent. So the three reader
commands read a rerun folder with a `-r` / `--rerun` selector rather than a separate command:

| Invocation | Reads |
| --- | --- |
| `check-test-result` | `outputs/` — the full run, unchanged |
| `check-test-result --rerun` | the most recently modified `outputs/rerun-*/` |
| `check-test-result --rerun "login flow"` | `outputs/rerun-login_flow/` |

The same selector works on [`get-failure-detail`](#get-failure-detail-usage) and
[`output-context-variables`](#output-context-variables-usage).

To read the full run and *every* rerun at once instead of selecting one, use
[`get-test-report`](#get-test-report-usage), which emits them as a single JSON document and
reports each rerun under the name this selector accepts.

**Names are normalized exactly the way the agent normalizes them** when it creates the folder:
lower-cased, whitespace runs collapsed to a single `_`, and any other character stripped. So
`"login flow"`, `"Login Flow"`, and `login_flow` all select `outputs/rerun-login_flow/`.
Underscores you typed are preserved — `login__flow` selects `outputs/rerun-login__flow/`, a
different folder.

As a convenience you may also paste a folder name straight from a listing: if
`rerun-<name>` does not exist and `<name>` itself begins with `rerun-`, that prefix is dropped
and the result retried. This is strictly a fallback — the literal name always wins, so a rerun
genuinely named `rerun-login_flow` (folder `outputs/rerun-rerun-login_flow/`) is never shadowed
by the unrelated rerun named `login flow`.

**The most recent rerun is chosen by modification time, not by number.** The auto-numbered
suffix is the *lowest free* integer rather than a sequence — deleting `rerun-2` makes the next
unnamed rerun reuse it — and named folders carry no number at all.

If the requested folder does not exist (or no `rerun-*` folder exists at all), the command
exits non-zero and says so. It deliberately does **not** fall back to `outputs/`: reporting the
full run's result as though it were the rerun's is the failure this selector exists to remove.

#### Two caveats inherited from the agent

1. **A rerun that fails before running any task writes no `test-results.json` anywhere.** A
   full run records an `incomplete` result in that case; the rerun entry point does not. So
   `--rerun` with no name can resolve to an *older* rerun folder and report its result as
   current. If you have just run `rerun-tests` and the output looks stale, check the timestamps
   in `/agent/outputs/`. To remove the ambiguity, give each rerun a `name` in
   `rerun-config.json` and select it explicitly.
2. **A rerun's `agent.log` is split across two folders.** The rerun entry point redirects its
   logger only after loading config and skills, so those startup lines land in the *top-level*
   `outputs/agent.log`. `check-test-result --rerun` (when no results file is found) and
   `get-failure-detail --rerun` therefore also print that file, labeled as pre-rerun startup
   output — that is where an early rerun failure is actually recorded.

### Relationship to run-qa

`rerun-tests` and `run-qa` share one lock and one session record, because both drive the same
virtual display and the same MCP services. They can never run at the same time. The session
record (`/tmp/run-qa.session`) holds the active mode plus the orchestrator and agent PIDs with
their process start times, so each command can name the right stop command and each stopper can
prove a recorded PID is still the process that was recorded before terminating it.

The record is removed by its owner's exit trap, by either stopper, and on sight when found
stale; a record left behind by a `SIGKILL` is overwritten wholesale by the next session.

The stoppers take the lock before removing anything. Terminating the agent lets the old
orchestrator exit and release its lock, so a replacement session can start and write its own
record before a stopper reaches its cleanup — taking the lock first means a stopper only ever
deletes a record no live session owns. The orchestrators' own exit trap needs no such check:
it runs while their lock FD is still open, so they still hold the lock. Both
orchestrators refuse to start if the record cannot be written, since the stoppers would
otherwise have no way to find the session.

### Examples
```bash
# Full run first, to produce checkpoints
run-qa

# Then replay a subset
generate-rerun-config -f test-2.md --name "login flow" \
  | upload-instruction-file rerun-config.json
rerun-tests
# results land in /agent/outputs/rerun-login_flow/

# If a previous rerun session is still active, stop it first
stop-rerun
rerun-tests
```

## stop-qa Usage

`stop-qa` stops the currently tracked orchestrator process tree, including the launched agent subprocess, if one exists. Each recorded PID is validated against its start time first, so a stale record is discarded rather than acted on. The orchestrator and agent are validated independently, which lets `stop-qa` reap an agent that was left reparented by a `SIGKILL`ed orchestrator. It is the universal stopper: it stops a `run-qa` session *or* a `rerun-tests` session, whichever is active. It is also the only command that clears a stale lock left by an orphaned process.

To stop only a rerun — and be told to leave a `run-qa` session alone — use [`stop-rerun`](#stop-rerun-usage).

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

## stop-rerun Usage

`stop-rerun` stops an active `rerun-tests` session. It is scoped to reruns on purpose: because
`run-qa` and `rerun-tests` share one session record, this command consults the mode recorded in
it and refuses to terminate a `run-qa` session.

```bash
stop-rerun
```

| Situation | Behavior | Exit code |
| --- | --- | --- |
| A `rerun-tests` session is active | Stops the agent process tree, then the orchestrator; clears the session record | `0` |
| A `run-qa` session is active | Stops nothing; reports the active session and points at `stop-qa` | `1` |
| The record is stale (neither PID validates) | Stops nothing; reports the record as stale, discards it, and points at `stop-qa` | `0` |
| Nothing is tracked | Reports that no rerun was found, and points at `stop-qa` for stale-lock recovery | `0` |

A session whose recorded mode is missing or unrecognized is treated as `run-qa`, so `stop-rerun`
never terminates a process tree it cannot positively identify as a rerun.

Identity is verified before anything is terminated. A recorded PID alone proves nothing: a
`SIGKILL`ed orchestrator never runs its cleanup trap, so its record outlives it while the lock
is released — and if that PID is later recycled, acting on the record would terminate an
unrelated process tree as root. Both stoppers therefore compare each recorded PID's process
start time against the running process, and treat any mismatch as stale. The orchestrator is
re-validated a second time immediately before it is terminated, because stopping the agent
first can block for several seconds — long enough for the orchestrator's `wait` to return and
for it to exit on its own.

`stop-rerun` deliberately does **not** duplicate `stop-qa`'s orphaned-lock recovery. An orphaned
lock with no session record carries no mode information, so stale-lock recovery lives only in
`stop-qa` — and that recovery never touches a lock held by a session that is actually running:
`stop-qa` re-checks for a live session first and leaves it alone.

### Examples
```bash
# Stop the current rerun session, if any
stop-rerun

# Restart a rerun from scratch
stop-rerun
rerun-tests
```

## run-qa-lib (internal shared library)

`run-qa-lib` is a shared bash library sourced by `run-qa`, `rerun-tests`, `stop-qa`, `stop-rerun`, `check-test-result`, `get-failure-detail`, `output-context-variables`, and `get-test-report`. It covers two concerns: single-instance session tracking for the two orchestrators, and output-directory resolution for the readers. It is not intended to be invoked directly.

It consolidates logic that was previously duplicated across `run-qa` and `stop-qa`:

| Symbol | Description |
| --- | --- |
| `RUN_QA_LOCK_FILE` | Path to the exclusive lock file (`/tmp/run-qa.lock`), shared by `run-qa` and `rerun-tests` |
| `RUN_QA_SESSION_FILE` | Path to the session record (`/tmp/run-qa.session`) |
| `terminate_pid_tree <pid>` | Recursively terminates a process and all its children |
| `run_qa_process_start_time <pid>` | Echoes a PID's start time from `/proc`; returns `1` if it cannot be determined |
| `run_qa_write_session <mode> [agent_pid] [agent_start]` | Writes the record for the current process |
| `run_qa_set_agent [pid]` | Records the agent subprocess in the record; clears it when called with no argument |
| `run_qa_read_session` | Loads the record into `RUN_QA_SESSION_{MODE,PID,START,AGENT_PID,AGENT_START}` |
| `run_qa_clear_session` | Removes the record and any temp file left by an interrupted write |
| `run_qa_clear_session_if_unlocked` | Same, but only when no live session holds the lock; returns `1` and removes nothing otherwise |
| `run_qa_pid_matches <pid> <start>` | Returns `0` only if the PID is alive *and* is the same process the record was written for |
| `is_run_qa_active` | Returns `0` if a **validated** `run-qa` or `rerun-tests` session is running, `1` otherwise; sets `$RUN_QA_ACTIVE_PID` |
| `run_qa_session_mode` | Echoes the active session's mode, `run-qa` or `rerun-tests`; a missing or unrecognized record reads as `run-qa` |
| `run_qa_normalize_rerun_name <name>` | Echoes a rerun name as its folder suffix, a faithful mirror of the agent's normalization (lower-case, whitespace runs to `_`, other characters stripped). A leading `rerun-` is **preserved**, because the agent preserves it; returns `1` if nothing survives |
| `run_qa_resolve_output_dir <agent_path> <mode> [name]` | Echoes the directory a reader command should read from: `<agent_path>/outputs` for mode `run`, or the named — or most recently modified — `outputs/rerun-*` folder for mode `rerun`. A name that itself begins with `rerun-` is retried without that prefix, but only as a fallback once the literal folder is absent. Returns `1` with a message on stderr when no folder matches |
| `run_qa_list_rerun_dirs <agent_path>` | Echoes every existing `<agent_path>/outputs/rerun-*` folder, one per line, oldest first by modification time; echoes nothing and returns `0` when there are none. Used by `get-test-report`, which reads them all, rather than resolving a single one |

---

## agent-file-perms-lib (internal shared library)

`agent-file-perms-lib` is a shared bash library sourced by every manager script that writes into `$AGENT_PATH/tasks`, `$AGENT_PATH/instructions`, or `$AGENT_PATH/skills`. It is not intended to be invoked directly.

It exposes two helpers:

| Symbol | Description |
| --- | --- |
| `enforce_managed_file_perms <path>` | If `<path>` lives under a `tasks/`, `instructions/`, or `skills/` directory and exists, set its mode to `640` (owner `rw`, group `r`, others none). Paths outside those directories, empty arguments, and missing files are ignored; `chmod` failures are tolerated. |
| `enforce_managed_dir_perms <path>` | If `<path>` is a directory under a `tasks/`, `instructions/`, or `skills/` path and the caller is `root`, set its group to `agentgroup` and mode to `2550` (setgid; `r-x` for owner and group, nothing for others) so `agentuser` can traverse and read it. Paths outside those directories, non-directories, empty arguments, and non-root callers are ignored; `chgrp`/`chmod` failures are tolerated. The root guard exists because a `2550` directory drops the owner write bit, which would lock a non-root dev user out of a later overwrite. |

`/agent/tasks`, `/agent/instructions`, and `/agent/skills` are root-owned (`2550`, i.e. `550` + setgid) and the agent reads from them as a member of `agentgroup`. The manager scripts run as `root`, so a freshly written file or directory would otherwise default to a world-readable mode. After each write, the owning script calls `enforce_managed_file_perms` (and, for scripts that create subdirectories such as `load-test-skills`, `enforce_managed_dir_perms`) so `agentgroup` keeps read access while the entry is never left world-readable.

Callers: `upload-test-task`, `upload-instruction-file`, `load-test-skills`, `manage-global-constants`, `preset-context`, `set-domain-permission`, `manage-test-files`, `config-ai-provider`, `enable-test-on-host`, and `customize-playwright-config`.

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
check-test-result [-ap <agent-path>] [-r|--rerun [name]]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-r`, `--rerun [name]` | Read a rerun's results instead of the full run's. With no name, reads the most recent rerun (by folder modification time). See [Reading rerun results](#reading-rerun-results) |
| `-h`, `--help`, `h`, `help` | Show usage help |

An unrecognized option is rejected with exit `1` rather than ignored, so a mistyped selector can never quietly print the full run's results in place of a rerun's.

### Output
| Condition | Output |
| --- | --- |
| `run-qa` or `rerun-tests` is currently active | A message indicating testing is in progress, naming the mode and the orchestrator PID |
| `test-results.json` exists | The `exit_condition` value from the results file |
| `test-results.json` missing, `agent.log` missing | `ℹ️  No test results found.` |
| `test-results.json` missing, `agent.log` exists | `ℹ️  No test results found.` followed by the full content of `agent.log` |

Under `--rerun`, every path above resolves inside the selected `outputs/rerun-<name>/` folder, and the "no test results" case additionally prints the top-level `outputs/agent.log` (see [Reading rerun results](#reading-rerun-results)). The name of the folder being read is written to **stderr**, so stdout carries exactly what it does today.

### Examples
```bash
# Check results after a run
check-test-result

# Check the most recent rerun's results
check-test-result --rerun

# Check a specific rerun's results
check-test-result --rerun "login flow"

# Check results using a custom agent path
check-test-result -ap /tmp/my-agent
```

---

## get-failure-detail Usage

`get-failure-detail` prints a full diagnostic report for the first failed test found in `$AGENT_PATH/outputs/test-results.json`. If a test run is still in progress, it reports that instead.

```bash
get-failure-detail [-ap <agent-path>] [-d] [-r|--rerun [name]]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-d` | Include API log (`$AGENT_PATH/outputs/api-log.json`) at the end of the report |
| `-r`, `--rerun [name]` | Read a rerun's results instead of the full run's. With no name, reads the most recent rerun (by folder modification time). See [Reading rerun results](#reading-rerun-results) |
| `-h`, `--help`, `h`, `help` | Show usage help |

An unrecognized option is rejected with exit `1` rather than ignored.

### Output when a failed test is found

Each section is printed in order. Missing files are reported inline and do not abort the output.

| Section | Source |
| --- | --- |
| **Failed Test Summary** | The failed test JSON object from `test-results.json` |
| **Test Detail** | `$AGENT_PATH/tasks/<test-file>` |
| **Test Steps** | `$AGENT_PATH/outputs/<test-file-stem>_log.json` |
| **Test Context** | `$AGENT_PATH/outputs/test-context.json` |
| **Agent Log** | `$AGENT_PATH/outputs/agent.log` |
| **Pre-rerun Startup Log** _(only with `--rerun`, only if file exists)_ | `$AGENT_PATH/outputs/agent.log` |
| **API Log** _(only with `-d`, only if file exists)_ | `$AGENT_PATH/outputs/api-log.json` |

Under `--rerun`, every `outputs/` path above resolves inside the selected `outputs/rerun-<name>/` folder instead — except **Test Detail**, which reads `$AGENT_PATH/tasks/<test-file>`: task files live outside `outputs/` and are the same ones a rerun replays.

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

## get-test-report Usage

`get-test-report` prints the full run's results together with every rerun's results as a single JSON document, read from `$AGENT_PATH/outputs/test-results.json` and each `$AGENT_PATH/outputs/rerun-*/test-results.json`. Unlike `check-test-result`, which reads one directory at a time, this command reads them all.

```bash
get-test-report [-ap <agent-path>] [--list-tests | --list-results]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `--list-tests` | Instead of the full report, list only the `name` and `file` of each test in the run's `results`. Rerun folders are not read |
| `--list-results` | Instead of the full report, list only `test_name`, `test_type`, `status` and `exit_condition` for the run and for each rerun |
| `-h`, `--help`, `h`, `help` | Show usage help |

`--list-tests` and `--list-results` are mutually exclusive; supplying both exits `1`. Repeating the same flag is accepted. An unrecognized option is rejected with exit `1` rather than ignored.

**stdout is always JSON and nothing else.** Every diagnostic — the in-progress error, the not-available error, and per-rerun skip warnings — goes to **stderr**, so `get-test-report | jq …` and `get-test-report > report.json` are always safe.

### Output
| Condition | stdout | Exit |
| --- | --- | --- |
| `run-qa` or `rerun-tests` is currently active | — (message on stderr, naming the mode and PID) | `1` |
| `outputs/test-results.json` missing, empty, unparseable, or not exactly one JSON object | — (`ERROR: test report isn't available.` on stderr) | `1` |
| Run results present, no `rerun-*` folders | `{"test_run": …}`, with **no** `reruns` key | `0` |
| Run results present, reruns present | `{"test_run": …, "reruns": [ … ]}` | `0` |
| A `rerun-*` folder has no or unparseable results | that rerun is omitted; `⚠️  Skipping rerun "<name>": …` on stderr, naming whether the file was missing or unreadable | `0` |

The `reruns` array is ordered oldest to newest by folder modification time — the same ordering `--rerun` with no name uses to pick the latest, and for the same reason (see [Reading rerun results](#reading-rerun-results)). Each element is `{"name": …, "test_result": …}`, where `name` is the folder's basename without its `rerun-` prefix, i.e. exactly the value to pass to `check-test-result --rerun <name>`.

> **`name` is not `test_name`.** The `name` this command reports is derived from the folder (`rerun-login_flow` → `login_flow`, `rerun-1` → `1`) and is what the `--rerun` selector accepts. The `test_name` *inside* `test-results.json` is the rerun's human-readable identity: the raw, un-normalized `name` from `rerun-config.json` (`login flow`, space included), or the folder basename **with** its prefix (`rerun-1`) when the config supplied no name. A regular run has no `test_name` key at all.

### Simplified output

`--list-tests` reads only the run's `results` array. `file` is the field a rerun config needs — `flow` entries accept `file` and nothing else, and each value is accepted verbatim by [`generate-rerun-config -f`](#generate-rerun-config-usage):

```json
[
  { "name": "Test Wikipedia English Language Banner", "file": "test-wikipedia-english.md" },
  { "name": "Login flow", "file": "test-2.md" }
]
```

`--list-results` emits one object per run — the full run first, then each rerun oldest first — carrying only the four run-level fields, in the order the results file stores them. No `results` array from any run is included. Keys absent from the source stay absent rather than being emitted as `null`:

```json
[
  { "status": "complete", "exit_condition": "1 test failed", "test_type": "regular" },
  { "status": "complete", "exit_condition": "all tests passed",
    "test_type": "rerun", "test_name": "login flow" },
  { "status": "incomplete", "exit_condition": "1 test failed",
    "test_type": "rerun", "test_name": "rerun-1" }
]
```

The `status` here is the **run-level** `complete`/`incomplete`, not a test's pass/fail — per-test status lives in `results`, which this mode never reads.

### Examples
```bash
# Full combined report
get-test-report

# Which reruns exist, by the name --rerun accepts
get-test-report | jq -r '.reruns[].name'

# The task filenames available for a rerun-config flow
get-test-report --list-tests | jq -r '.[].file'

# How the run and each rerun ended
get-test-report --list-results

# Save the report; warnings stay on stderr and out of the file
get-test-report > report.json

# Use a custom agent path
get-test-report -ap /tmp/my-agent
```

---

## generate-rerun-config Usage

`generate-rerun-config` composes a `rerun-config.json` document and prints it to stdout. It writes nothing to disk — pipe it to [`upload-instruction-file`](#upload-instruction-file-usage) to install it. It is the write-side counterpart to [`get-test-report --list-tests`](#simplified-output), which lists the task filenames a `flow` can hold.

```bash
generate-rerun-config [-ap <agent-path>] -f <task-file> [-f <task-file> ...]
                      [--name <rerun-name>] [--data KEY=value,...] [--data-file <path>]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-f`, `--file <name>` | Task file to replay. Repeatable; **the order given is the execution order**. At least one is required |
| `--name <rerun-name>` | Name the rerun, and with it its output folder. Omitted from the document when not given |
| `--data KEY=value,...` | Context overrides merged into `data`. Repeatable. Dotted keys nest: `user.name=Ada` → `{"user":{"name":"Ada"}}` |
| `--data-file <path>` | A JSON file whose top-level object is merged into `data`. Repeatable. Use it for values that are not strings |
| `-h`, `--help`, `h`, `help` | Show usage help |

**stdout is always JSON and nothing else.** Every diagnostic — errors, the duplicate-file warning, the existing-folder warning, and the folder-name notice — goes to **stderr**, so no diagnostic can corrupt a piped document.

> **A pipe does not stop on failure — the upload does.** On a validation error this command exits non-zero with *empty* stdout, but a pipeline's exit status is its **last** command's. [`upload-instruction-file`](#upload-instruction-file-usage) therefore rejects empty stdin and leaves any existing file untouched, so a failed generation cannot blank a working config. The pipeline still reports the upload's exit status, so check it, or capture first when you want the generator's own:
>
> ```bash
> cfg=$(generate-rerun-config -f test-2.md) \
>   && printf '%s\n' "$cfg" | upload-instruction-file rerun-config.json
> ```

An unrecognized option is rejected with exit `1` rather than ignored, and a value-taking flag rejects a following flag (`-f --name x`) rather than consuming it.

`name` and `data` are **omitted rather than emitted empty**. Both are optional to the agent, and `"data": {}` would misrepresent a config that overrides nothing.

### Validation

Every task filename is checked against `$AGENT_PATH/tasks` before anything is emitted. This is the point of the command: `rerun-tests` only pre-flights whether the config file *exists*, so an unknown `file`, an illegal `name`, or an occupied output folder otherwise surfaces from the agent **after** the virtual display and both MCP services have started.

| Condition | stdout | Exit |
| --- | --- | --- |
| No `-f` given | — (`flow` may not be empty) | `1` |
| A `-f` value is not a file in `$AGENT_PATH/tasks` | — (error names it and lists the available files) | `1` |
| A `-f` value contains `/` | — (flow entries are matched by basename) | `1` |
| `--name` is blank, or normalizes to empty or to a plain number | — (mirrors the agent's own two rules) | `1` |
| `--data-file` is missing, unparseable, or is not exactly one JSON object | — | `1` |
| A `-f` value is repeated | the document, with the repeat kept | `0` (warning on stderr) |
| `outputs/rerun-<normalized>/` already exists | the document | `0` (warning on stderr) |
| Otherwise | `{"name"?: …, "flow": [ … ], "data"?: { … }}` | `0` |

A repeated `-f` is kept because replaying one task twice in a flow is legal; it warns because a repeat is more often a typo. An existing rerun folder is fatal to `rerun-tests` but only a warning here — you may be about to remove it, and this command's exit status does not depend on output state it does not own.

**`--name` is normalized by the agent** to form the folder name: lower-cased, whitespace runs collapsed to `_`, and every other character stripped. `--name "Login Flow"` writes `"name": "Login Flow"` — the raw value, verbatim — but produces `outputs/rerun-login_flow/`. Because that is lossy, the resolved folder is reported on stderr. A name that normalizes to nothing (`"!!!"`) or to a plain number (`"12"`, which would collide in form with the auto-numbered `rerun-N` scheme) is rejected here rather than by the agent. A name beginning with `-` cannot be passed at all, since every value-taking flag rejects a `-`-prefixed value rather than consuming it; write such a config by hand if you need one. See [Reading rerun results](#reading-rerun-results) for how the two forms are used afterwards.

### `data` precedence

Sources are applied in this order, so the command line wins over a file: every `--data-file` first, in the order given, then every `--data`. Repeating either flag accumulates, with later occurrences overriding earlier ones.

`--data` values are always strings. Use `--data-file` for numbers, booleans, arrays, or nested objects — `data` values are unvalidated by the agent, so any JSON is legal. Key parsing matches [`preset-context variables set`](#preset-context-usage) exactly: case-sensitive, comma-delimited, values optionally double-quoted, dotted keys consolidated into nested objects.

### Examples
```bash
# Minimal
generate-rerun-config -f test-2.md

# Named rerun, two tasks, context overrides
generate-rerun-config -f test-2.md -f test-5.md --name "login flow" \
  --data user_email=qa+rerun@example.com

# Install it, without clobbering a working config if generation fails
cfg=$(generate-rerun-config -f test-2.md -f test-5.md --name "login flow") \
  && printf '%s\n' "$cfg" | upload-instruction-file rerun-config.json

# Which task filenames are available for a flow
get-test-report --list-tests | jq -r '.[].file'

# Non-string values (numbers, arrays, nested objects) come from a file
generate-rerun-config -f test-2.md --data-file ./overrides.json

# Preview without installing
generate-rerun-config -f test-2.md --name nightly | jq .

# Use a custom agent path
generate-rerun-config -ap /tmp/my-agent -f test-2.md
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
config-ai-provider --provider <provider> --model <model> --mode <default|efficiency> \
  [--base-url <url>] [--extra-headers <json>] [--temperature <value>] [--temperature-enabled <true|false>] \
  [-ap <agent-path>] [-cp <config-helpers-path>]
```

### Options
| Option | Description |
| --- | --- |
| `--provider <value>` | Provider value written directly to `AI_PROVIDER` (for example: `openai`) |
| `--model <value>` | Model value written directly to `AI_MODEL` |
| `--mode <value>` | Mode selector: `default` -> `<provider>-default.env`, `efficiency` -> `<provider>-token-efficiency.env` |
| `-b`, `--base-url <url>` | Written to `AI_BASE_URL`. **Required** for `--provider openai-compatible`; honored by `gemma`; ignored (with a warning) by every other provider |
| `--extra-headers <json>` | JSON object of string values, written to `AI_EXTRA_HEADERS`. Used only by `openai-compatible` |
| `--temperature <value>` | Written to `AI_TEMPERATURE`. Sent only by `openai-compatible` |
| `--temperature-enabled <true\|false>` | Written to `AI_TEMPERATURE_ENABLED`. Set `false` for reasoning models that reject a temperature field. Used only by `openai-compatible` |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-cp <path>` | Override the config helpers path (default: `/config-helpers`) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior

- Uses the same mode-file update flow as `config-agent` option `1`.
- Respects provider locking: once a provider is configured, switching to a different provider requires a new container.
- Does **not** append Gemma extra instructions.
- All four optional flags are validated **before** anything is written; a rejected call leaves `agent-config.json` untouched.
- `--provider openai-compatible` without `--base-url` is an error. The agent itself throws at startup
  without one, so this fails at config time instead of at run time.
- `--base-url` is used **verbatim** for `openai-compatible` — only `/chat/completions` is appended,
  so supply the vendor's full base path including any version segment. For `gemma` it is the bare
  Ollama host and `/v1` is appended.
- `--extra-headers` must parse as a JSON object of string values. **Its value is never echoed**, not
  even in the validation error, because `AI_EXTRA_HEADERS` is marked `sensitive` and routinely
  carries credentials. The applied-settings summary prints `AI_EXTRA_HEADERS=<set>`.
- A flag aimed at a provider that ignores it warns on stderr and still applies; the value is inert
  in `agent-config.json`.

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

# OpenRouter through the openai-compatible adapter, with routing headers
config-ai-provider \
  --provider openai-compatible \
  --model qwen/qwen3-235b-a22b \
  --mode efficiency \
  --base-url https://openrouter.ai/api/v1 \
  --extra-headers '{"HTTP-Referer":"https://duotail.com","X-Title":"waterwheel"}'

# Groq -- note the non-/v1 base path
config-ai-provider \
  --provider openai-compatible \
  --model llama-3.3-70b-versatile \
  --mode default \
  --base-url https://api.groq.com/openai/v1

# A self-hosted reasoning model that rejects an explicit temperature
config-ai-provider \
  --provider openai-compatible \
  --model deepseek-ai/DeepSeek-R1-Distill-Qwen-32B \
  --mode default \
  --base-url http://host.docker.internal:8000/v1 \
  --temperature-enabled false

# Gemma against an Ollama server on the host
config-ai-provider \
  --provider gemma \
  --model gemma4:e4b \
  --mode default \
  --base-url http://host.docker.internal:11434
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
- `aiBaseUrl`

Lookup order per key:

1. Environment variable
2. `default` in `$AGENT_PATH/config/agent-config.json` under `env-params[]`

Key mapping:

- `aiProvider` -> `AI_PROVIDER`
- `aiModel` -> `AI_MODEL`
- `tokenMode` -> `CONTEXT_COMPRESSION`
- `aiBaseUrl` -> `AI_BASE_URL`

`aiBaseUrl` is an empty string for providers that do not use one. It matters most for
`openai-compatible`, where two configs can agree on provider, model and token mode while pointing at
entirely different vendors.

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
reset-test-config [-ap <agent-path>] [-cp <config-helpers-path>] [-t] [-i]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-cp <path>` | Override the config-helpers path (default: `/config-helpers`) |
| `-t` | Delete all `.md` files under `$AGENT_PATH/tasks` |
| `-i` | Delete all files under `$AGENT_PATH/instructions` except `email-permissions.yaml` |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- When neither `-t` nor `-i` is provided, **both** operations are performed.
- `email-permissions.yaml` is always preserved when resetting instructions.
- Resetting instructions also clears the `extra-instructions` entries (such as `host-testing`) from the agent config status file, since the `extra-instructions.md` file that backs them is deleted. Other status keys (`provider-mode`) are preserved, and the status file is removed entirely if nothing else remains. This keeps host-testing state consistent — without it, `config-agent` would still report host testing as enabled after a reset.
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

## customize-playwright-config Usage

`customize-playwright-config` customizes `$AGENT_PATH/instructions/playwright-mcp-config.json` using `/config-helpers/playwright-mcp-config-default.json` as the base template. All operations are replace-only: each run rewrites the output file from the template without accumulating previous customizations.

```bash
customize-playwright-config [-ap <agent-path>] [-cp <config-helpers-path>] <operation> [args]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-cp <path>` | Override the config-helpers path (default: `/config-helpers`) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Operations
| Operation | Arguments | Description |
| --- | --- | --- |
| `--clear` | — | Remove `$AGENT_PATH/instructions/playwright-mcp-config.json` if it exists; do nothing otherwise. Cannot be combined with other operations. |
| `--treat-as-secure` | `<domain1,domain2,...>` | Grant secure-context browser APIs to the given HTTP origins. Adds `--unsafely-treat-insecure-origin-as-secure=<domains>` and `--ignore-certificate-errors` to the Chromium launch args. Domains are comma-delimited HTTP URLs. |

### Examples
```bash
# Grant secure-context APIs to local dev server origins
customize-playwright-config --treat-as-secure http://host.docker.internal:8080,http://host.docker.internal:8081
# Produces playwright-mcp-config.json with:
# "args": [
#   "--disable-gpu",
#   "--disable-setuid-sandbox",
#   "--unsafely-treat-insecure-origin-as-secure=http://host.docker.internal:8080,http://host.docker.internal:8081",
#   "--ignore-certificate-errors"
# ]

# Use a custom agent path
customize-playwright-config -ap /tmp/my-agent --treat-as-secure http://host.docker.internal:8080

# Remove the customized config (revert to default Playwright MCP behavior)
customize-playwright-config --clear
```

---

## upload-instruction-file Usage

`upload-instruction-file` creates or replaces a file under `$AGENT_PATH/instructions` using content read from stdin. The `<filename>` argument is appended to `$AGENT_PATH/instructions` to form the full target path (it is passed to `file-upload-lib`). This is a convenient way to push instruction/config files (e.g. `allowed-domains.yaml`, `email-permissions.yaml`, `extra-instructions.md`) into the agent without editing files in place.

```bash
upload-instruction-file [-ap <agent-path>] [--allow-empty] <filename>
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `--allow-empty` | Permit empty stdin, writing a zero-byte file |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- Content is read from stdin and written to `$AGENT_PATH/instructions/<filename>`.
- Missing parent directories are created automatically (e.g. a nested `<filename>`).
- **Empty stdin is rejected** with exit `1`, and any existing file is left byte-for-byte unchanged. Any directory the rejected upload created is rolled back too — otherwise the leftover directory would make `load-test-skills` treat the skill as already loaded and silently skip the retry. A command that fails writes nothing and exits non-zero, but a pipeline reports its *last* command's status — so without this, `some-generator | upload-instruction-file config.json` would report success while blanking a working config. Pass `--allow-empty` to write a zero-byte file deliberately. The same guard applies to [`upload-test-task`](#upload-test-task-usage) and `load-test-skills`, which share `file-upload-lib`; neither exposes the flag, since an empty test task or skill file has no meaning.
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

## load-test-skills Usage

`load-test-skills` creates a skill folder under the skills directory and writes stdin content to a `SKILL.md` inside it. The skills directory is `$SKILLS_DIR` when set, otherwise `$AGENT_PATH/skills`; the `-name <skill-name>` argument becomes the folder name and the target file is `<skills-dir>/<skill-name>/SKILL.md` (written via `file-upload-lib`). By default an existing skill folder is left untouched; pass `--force`/`-f` to overwrite its `SKILL.md`.

```bash
load-test-skills [-ap <agent-path>] -name <skill-name> [--force]
```

### Options
| Option | Description |
| --- | --- |
| `-name`, `--name <skill-name>` | Name of the skill folder to create (required) |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-f`, `--force` | Overwrite an existing skill folder's `SKILL.md` |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- Content is read from stdin and written to `<skills-dir>/<skill-name>/SKILL.md`.
- `$SKILLS_DIR` overrides the default `$AGENT_PATH/skills` location.
- A skill name containing a path separator (or `.`/`..`) is rejected so it stays a single folder.
- An existing skill folder is skipped (stdin is drained, exit `0`) unless `--force` is given.
- Missing parent directories are created automatically.
- When run as `root`, the new folder is set to `root:agentgroup` `2550` and `SKILL.md` to `640` so `agentuser` can read them (see [`agent-file-perms-lib`](#agent-file-perms-lib-internal-shared-library)).

### Examples
```bash
# Create a skill from stdin
cat ./SKILL.md | load-test-skills -name login-flow

# Overwrite an existing skill
cat ./SKILL.md | load-test-skills -name login-flow --force

# Use a custom skills directory
cat ./SKILL.md | SKILLS_DIR=/tmp/skills load-test-skills -name login-flow
```

---

## display-test-skills Usage

`display-test-skills` lists installed skills, or prints a single skill's `SKILL.md`. Skills are read from two locations: `$AGENT_PATH/builtin-skills` (shipped with the image) and the user skills directory — `$SKILLS_DIR` when set, otherwise `$AGENT_PATH/skills` (loaded via `load-test-skills`). Without arguments it lists every skill in both, tagging built-in skills with `(built-in)`. With `--show <skill-name>` it prints that skill's `SKILL.md`, preferring a user skill over a built-in one of the same name, and prints `No skill is matched.` when neither exists.

```bash
display-test-skills [-ap <agent-path>] [--show|-s <skill-name>]
```

### Options
| Option | Description |
| --- | --- |
| `-s`, `--show <skill-name>` | Print the named skill's `SKILL.md` instead of listing |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- List mode enumerates skill folders under `builtin-skills/` (marked `(built-in)`) then the user skills directory; if neither has any, it prints `No skills installed.`.
- Show mode looks up `<skills-dir>/<name>/SKILL.md` first, then `builtin-skills/<name>/SKILL.md`, so a user skill shadows a built-in of the same name.
- `$SKILLS_DIR` overrides the default `$AGENT_PATH/skills` location for the user skills directory.
- A skill name containing a path separator (or `.`/`..`) is rejected.
- When the named skill is not found in either location, it prints `No skill is matched.` and exits `0`.

### Examples
```bash
# List all installed skills (built-in and user)
display-test-skills

# Print a specific skill's SKILL.md
display-test-skills --show login-flow

# Short flag against a custom agent path
display-test-skills -ap /agent -s login-flow
```

---

## delete-test-skills Usage

`delete-test-skills` removes skill folders that were loaded via `load-test-skills`. It either deletes a comma-delimited list of skill names (`-n`) or clears every user-defined skill (`-a`), removing each matching folder under the skills directory. The skills directory is `$SKILLS_DIR` when set, otherwise `$AGENT_PATH/skills`. Only user-loaded skills are affected — built-in skills under `$AGENT_PATH/builtin-skills` are never touched.

```bash
delete-test-skills [-ap <agent-path>] -n <name1,name2,...>
delete-test-skills [-ap <agent-path>] -a
```

### Options
| Option | Description |
| --- | --- |
| `-n`, `--names <names>` | Comma-delimited skill folder names to delete |
| `-a`, `--all` | Delete all user-defined skills under the skills directory (mutually exclusive with `-n`) |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- Exactly one of `-n` or `-a` is required; supplying both exits non-zero.
- With `-a`, every immediate subfolder of the skills directory is deleted; if the directory is missing or empty, the command still exits `0`.
- Each name is trimmed of surrounding whitespace, so `-names 'a, b'` works as expected.
- A matching folder `<skills-dir>/<name>` is removed recursively; a name with no matching folder is reported and skipped (the command still exits `0`).
- `$SKILLS_DIR` overrides the default `$AGENT_PATH/skills` location.
- Any name containing a path separator (or `.`/`..`) is rejected and the command exits non-zero before deleting anything further.
- On completion it prints a summary of how many skills were deleted and skipped.

### Examples
```bash
# Delete a single skill
delete-test-skills -n login-flow

# Delete several skills at once
delete-test-skills -n login-flow,checkout-flow

# Delete all user-defined skills
delete-test-skills -a

# Use a custom skills directory
SKILLS_DIR=/tmp/skills delete-test-skills -n login-flow
```

---

## delete-builtin-skills Usage

`delete-builtin-skills` removes built-in skill folders that ship with the image, under `$AGENT_PATH/builtin-skills`. It deletes a comma-delimited list of skill names (`-n`), removing each exactly-matched folder. Unlike `delete-test-skills`, there is **no `-a`/`--all` option** — built-in skills can only be removed by exact name. A leading `ww:` prefix on a name is ignored, so `ww:foo` targets the folder `foo`.

```bash
delete-builtin-skills [-ap <agent-path>] -n <name1,name2,...>
```

### Options
| Option | Description |
| --- | --- |
| `-n`, `--names <names>` | Comma-delimited built-in skill folder names to delete |
| `-ap <path>` | Override the agent path (default: `/agent`) |
| `-h`, `--help`, `h`, `help` | Show usage help |

### Behavior
- `-n` is required; there is no bulk-delete option.
- Built-in skills live at `$AGENT_PATH/builtin-skills` (this location is not configurable via `$SKILLS_DIR`).
- A leading `ww:` prefix is stripped from each name before matching, so `ww:foo` and `foo` are equivalent.
- Each name is trimmed of surrounding whitespace, so `-n 'a, b'` works as expected.
- A matching folder `<builtin-skills>/<name>` is removed recursively; a name with no matching folder is reported and skipped (the command still exits `0`).
- Any name containing a path separator (or `.`/`..`, evaluated after the `ww:` prefix is stripped) is rejected and the command exits non-zero before deleting anything further.
- On completion it prints a summary of how many skills were deleted and skipped.

### Examples
```bash
# Delete a single built-in skill
delete-builtin-skills -n login-flow

# Delete several built-in skills at once
delete-builtin-skills -n login-flow,checkout-flow

# A "ww:" prefix targets the unprefixed skill name
delete-builtin-skills -n ww:login-flow
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

## output-context-variables Usage

`output-context-variables` prints the user-scoped context values produced by the latest run as a flat JSON object, read from `$AGENT_PATH/outputs/test-context.json`. Tests store values such as AI-generated usernames and passwords there; this command extracts the entries whose `scope` is `user` for reuse outside the container.

```bash
output-context-variables [-ap <agent-path>] [-r|--rerun [name]]
```

### Options
| Option | Description |
| --- | --- |
| `-ap <path>` | Override the agent path (default: `/agent`, or the `AGENT_PATH` environment variable) |
| `-r`, `--rerun [name]` | Read a rerun's results instead of the full run's. With no name, reads the most recent rerun (by folder modification time). See [Reading rerun results](#reading-rerun-results) |
| `-h`, `--help`, `h`, `help` | Show usage help |

An unrecognized option is rejected with exit `1` rather than ignored. Under `--rerun`, the folder being read is named on **stderr** only, so stdout stays pure JSON.

### Behavior
- Reports an error and exits non-zero if a `run-qa` run is currently active (exporting context variables while testing is in progress is not supported).
- Reports an error and exits non-zero if `$AGENT_PATH/outputs/test-context.json` does not exist.
- For each element whose `scope` is `user`, the `user.` prefix is stripped from its `key` to form the output key, and its `value` is used as the output value (objects, arrays, and scalars are preserved).
- Elements missing a `key` or `value` property are skipped.
- Prints an empty object `{}` when no user-scoped element is found.

### Examples
```bash
# Output user-scoped context values from the latest run
output-context-variables

# Output the most recent rerun's user-scoped context values
output-context-variables --rerun

# Use a custom agent path
output-context-variables -ap /tmp/my-agent
```

Given a `test-context.json` containing `user.testuser` and `user.channel` entries, the command prints:

```json
{
  "testuser": {
    "username": "test.user21",
    "email": "test.user21@enduser1.com"
  },
  "channel": "news"
}
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
| `/agent`                                    | `root:agentgroup` | `2775` | Read/write in owned subtrees; can add/move/delete top-level entries via group write | Setgid + group-writable so root-created MCP artifacts land in `agentgroup` and `agentuser` can manage them. When the agent saves a screenshot with an explicit filename, the (root) Playwright MCP resolves it against the agent's cwd (`/agent`) and writes it here; group write + setgid let `agentuser` move it into `/agent/outputs`. Agent code subtrees (`dist/`, `config/`, `node_modules/`) remain `agentuser`-owned. |
| `/agent/instructions`                       | `root:agentgroup` | `550` | Read + traverse, no write | Policy/config files are read-only at runtime; files written by the manager scripts are set to `640` (see `agent-file-perms-lib`) |
| `/agent/tasks`                              | `root:agentgroup` | `550` | Read + traverse, no write | Task input files are read-only at runtime; files written by the manager scripts are set to `640` (see `agent-file-perms-lib`) |
| `/agent/outputs`                            | `agentuser:agentgroup` | `770` | Full rwx | Agent writes logs and output artifacts here               |
| `/agent/bin`                                | `agentuser:agentgroup` | `770` | Full rwx | Writable bin directory for agent use                      |
| `/services/playwright`                      | `root:root` | `700` | No access | Playwright MCP service directory, root-only               |
| `/services/playwright/allowed-domains.yaml` | `root:root` | default file mode | Not accessible (parent dir `700`) | System fallback domain allowlist                          |
| `/services/email`                           | `root:root` | `700` | No access | Email MCP service directory, root-only                    |
| `/services/email/email-mcp.jar`             | `root:root` | default file mode | Not accessible (parent dir `700`) | Email MCP JAR, loaded by service script                   |
| `/usr/local/bin/run-qa`                     | `root:root` | `700` | Cannot execute | Container entrypoint script                               |
| `/usr/local/bin/stop-qa`                    | `root:root` | `700` | Cannot execute | Stops the tracked `run-qa` or `rerun-tests` process tree  |
| `/usr/local/bin/rerun-tests`                | `root:root` | `700` | Cannot execute | Replays a task subset from a checkpoint                   |
| `/usr/local/bin/stop-rerun`                 | `root:root` | `700` | Cannot execute | Stops the tracked `rerun-tests` process tree              |
| `/usr/local/bin/check-test-result`          | `root:root` | `700` | Cannot execute | Prints test results or in-progress status                 |
| `/usr/local/bin/get-failure-detail`         | `root:root` | `700` | Cannot execute | Prints full diagnostic report for the first failed test   |
| `/usr/local/bin/get-test-report`            | `root:root` | `700` | Cannot execute | Prints the full run and every rerun's results as one JSON document |
| `/usr/local/bin/output-context-variables`   | `root:root` | `700` | Cannot execute | Prints user-scoped context values from the latest run     |
| `/usr/local/bin/playwright-mcp`             | `root:root` | `700` | Cannot execute | Playwright MCP launch script                              |
| `/usr/local/bin/email-mcp`                  | `root:root` | `700` | Cannot execute | Email MCP launch script                                   |
| `/usr/local/bin/config-agent`               | `root:root` | `700` | Cannot execute | Script to quickly config the agent                        |
| `/usr/local/bin/config-ai-provider`         | `root:root` | `700` | Cannot execute | Non-interactively applies provider/model/mode settings    |
| `/usr/local/bin/run-qa-lib`                 | `root:root` | `700` | Cannot execute | Shared library sourced by `run-qa`, `rerun-tests`, `stop-qa`, `stop-rerun`, `check-test-result`, `get-failure-detail`, `output-context-variables`, `get-test-report` |
| `/usr/local/bin/file-upload-lib`            | `root:root` | `700` | Cannot execute | Saves stdin content to a target file path |
| `/usr/local/bin/agent-file-perms-lib`       | `root:root` | `700` | Cannot execute | Shared library that restricts `tasks/`-`instructions/` files to `640` |
| `/usr/local/bin/manage-global-constants`    | `root:root` | `700` | Cannot execute | Manages entries in `global-context.json`                  |
| `/usr/local/bin/manage-test-files`          | `root:root` | `700` | Cannot execute | Manages markdown test files in `/agent/tasks`             |
| `/usr/local/bin/preset-context`             | `root:root` | `700` | Cannot execute | Manages entries in `preset-context.json`                  |
| `/usr/local/bin/display-ai-config`          | `root:root` | `700` | Cannot execute | Prints effective AI provider/model/token mode as JSON     |
| `/usr/local/bin/display-test-skills`        | `root:root` | `700` | Cannot execute | Lists installed skills or prints a skill's `SKILL.md`     |
| `/usr/local/bin/reset-test-config`          | `root:root` | `700` | Cannot execute | Deletes task `.md` files and/or instruction files         |
| `/etc/profile.d/container_env.sh`           | `root:root` | `644` | Read-only | Environment variables forwarded from root to `agentuser`  |

### Command Availability Matrix

| Command / Action           | Root | `agentuser` | Invocation path                                          |
|----------------------------| --- | --- |----------------------------------------------------------|
| `run-qa`                   | ✅ | ❌ | `/usr/local/bin/run-qa` (mode `700`)                     |
| `stop-qa`                  | ✅ | ❌ | `/usr/local/bin/stop-qa` (mode `700`)                    |
| `rerun-tests`              | ✅ | ❌ | `/usr/local/bin/rerun-tests` (mode `700`)                |
| `stop-rerun`               | ✅ | ❌ | `/usr/local/bin/stop-rerun` (mode `700`)                 |
| `check-test-result`        | ✅ | ❌ | `/usr/local/bin/check-test-result` (mode `700`)          |
| `get-failure-detail`       | ✅ | ❌ | `/usr/local/bin/get-failure-detail` (mode `700`)         |
| `get-test-report`          | ✅ | ❌ | `/usr/local/bin/get-test-report` (mode `700`)            |
| `output-context-variables` | ✅ | ❌ | `/usr/local/bin/output-context-variables` (mode `700`)   |
| `config-agent`             | ✅ | ❌ | `/usr/local/bin/config-agent` (mode `700`)               |
| `config-ai-provider`       | ✅ | ❌ | `/usr/local/bin/config-ai-provider` (mode `700`)         |
| `file-upload-lib`          | ✅ | ❌ | `/usr/local/bin/file-upload-lib` (mode `700`)            |
| `agent-file-perms-lib`     | ✅ | ❌ | `/usr/local/bin/agent-file-perms-lib` (mode `700`)       |
| `manage-global-constants`  | ✅ | ❌ | `/usr/local/bin/manage-global-constants` (mode `700`)    |
| `manage-test-files`        | ✅ | ❌ | `/usr/local/bin/manage-test-files` (mode `700`)          |
| `preset-context`            | ✅ | ❌ | `/usr/local/bin/preset-context` (mode `700`)              |
| `display-ai-config`        | ✅ | ❌ | `/usr/local/bin/display-ai-config` (mode `700`)          |
| `display-test-skills`      | ✅ | ❌ | `/usr/local/bin/display-test-skills` (mode `700`)        |
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


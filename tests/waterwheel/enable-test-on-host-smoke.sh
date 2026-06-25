#!/usr/bin/env bash
set -euo pipefail

repo=/Users/taodong/Work/code/duotail-greenhouse
script="$repo/waterwheel/files/scripts/enable-test-on-host.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

agent="$tmpdir/agent"
helpers="$tmpdir/config-helpers"
mkdir -p "$agent/instructions" "$helpers"

# Seed config-helpers and instruction files.
printf 'Replace localhost with host.docker.internal during host testing.\n' > "$helpers/extra-local.md"
printf 'allowed:\n  - http://localhost:8080\n  - http://localhost:8025\n' > "$agent/instructions/allowed-domains.yaml"
printf '{\n  "LOGIN_URL": "http://localhost:8080/login",\n  "EMAIL_URL": "http://localhost:8025"\n}\n' > "$agent/instructions/global-context.json"

echo '== enabling host testing performs all the expected updates =='
bash "$script" -ap "$agent" -cp "$helpers"

extra="$agent/instructions/extra-instructions.md"
if ! grep -Fq '<!-- host-testing-start -->' "$extra" || ! grep -Fq '<!-- host-testing-end -->' "$extra"; then
  echo 'expected host-testing markers in extra-instructions.md' >&2
  exit 1
fi
if ! grep -Fq 'Replace localhost with host.docker.internal' "$extra"; then
  echo 'expected extra-local.md content appended to extra-instructions.md' >&2
  exit 1
fi
if ! grep -Fq '  - host-testing' "$helpers/agent-config-status.yaml"; then
  echo 'expected host-testing entry in status file' >&2
  exit 1
fi
if grep -q 'localhost' "$agent/instructions/allowed-domains.yaml"; then
  echo 'expected localhost rewritten in allowed-domains.yaml' >&2
  exit 1
fi
if grep -q 'localhost' "$agent/instructions/global-context.json"; then
  echo 'expected localhost rewritten in global-context.json' >&2
  exit 1
fi
if ! grep -Fq 'host.docker.internal:8080' "$agent/instructions/global-context.json"; then
  echo 'expected host.docker.internal in global-context.json' >&2
  exit 1
fi

echo '== re-running is idempotent (no duplicate host-testing block) =='
bash "$script" -ap "$agent" -cp "$helpers"
start_count=$(grep -cF '<!-- host-testing-start -->' "$extra")
if [ "$start_count" -ne 1 ]; then
  echo "expected a single host-testing block, found $start_count" >&2
  exit 1
fi
entry_count=$(grep -cF '  - host-testing' "$helpers/agent-config-status.yaml")
if [ "$entry_count" -ne 1 ]; then
  echo "expected a single host-testing status entry, found $entry_count" >&2
  exit 1
fi

echo '== works when global-context.json is absent =='
agent2="$tmpdir/agent2"
mkdir -p "$agent2/instructions"
bash "$script" -ap "$agent2" -cp "$helpers"
if [ -f "$agent2/instructions/global-context.json" ]; then
  echo 'did not expect global-context.json to be created' >&2
  exit 1
fi

echo '== missing extra-local.md fails with an error =='
agent3="$tmpdir/agent3"
mkdir -p "$agent3/instructions"
if bash "$script" -ap "$agent3" -cp "$tmpdir/missing-helpers"; then
  echo 'expected missing extra-local.md command to fail' >&2
  exit 1
fi

echo '== unknown option fails with an error =='
if bash "$script" -z; then
  echo 'expected unknown-option command to fail' >&2
  exit 1
fi

echo '== help option prints usage =='
help_output=$(bash "$script" -h)
printf '%s\n' "$help_output" | grep -Fq 'Usage: enable-test-on-host.sh'

echo 'all checks passed'

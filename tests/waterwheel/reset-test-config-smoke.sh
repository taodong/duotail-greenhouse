#!/usr/bin/env bash
set -euo pipefail

repo=/Users/taodong/Work/code/duotail-greenhouse
reset="$repo/waterwheel/files/scripts/reset-test-config.sh"
enable="$repo/waterwheel/files/scripts/enable-test-on-host.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

echo '== resetting instructions strips the extra-instructions array but keeps other keys =='
a1="$tmpdir/a1/agent"
h1="$tmpdir/a1/helpers"
mkdir -p "$a1/instructions" "$h1"
printf 'extra-instructions:\n  - host-testing\n  - gemma\nprovider-mode: openai-default\nsystem-prompt: cn\n' > "$h1/agent-config-status.yaml"
printf 'x\n' > "$a1/instructions/extra-instructions.md"
printf 'keep\n' > "$a1/instructions/email-permissions.yaml"
bash "$reset" -ap "$a1" -cp "$h1" -i >/dev/null
status="$h1/agent-config-status.yaml"
if grep -q 'host-testing' "$status" || grep -q 'extra-instructions:' "$status"; then
  echo 'expected extra-instructions array removed from status file' >&2
  cat "$status" >&2
  exit 1
fi
if ! grep -q 'provider-mode: openai-default' "$status" || ! grep -q 'system-prompt: cn' "$status"; then
  echo 'expected provider-mode and system-prompt keys preserved' >&2
  cat "$status" >&2
  exit 1
fi
if [ ! -f "$a1/instructions/email-permissions.yaml" ]; then
  echo 'expected email-permissions.yaml preserved' >&2
  exit 1
fi

echo '== status file is deleted when only extra-instructions entries remained =='
a2="$tmpdir/a2/agent"
h2="$tmpdir/a2/helpers"
mkdir -p "$a2/instructions" "$h2"
printf 'extra-instructions:\n  - host-testing\n' > "$h2/agent-config-status.yaml"
printf 'x\n' > "$a2/instructions/extra-instructions.md"
bash "$reset" -ap "$a2" -cp "$h2" -i >/dev/null
if [ -f "$h2/agent-config-status.yaml" ]; then
  echo 'expected status file to be deleted' >&2
  cat "$h2/agent-config-status.yaml" >&2
  exit 1
fi

echo '== tasks-only reset leaves the status file untouched =='
a3="$tmpdir/a3/agent"
h3="$tmpdir/a3/helpers"
mkdir -p "$a3/tasks" "$h3"
printf 'extra-instructions:\n  - host-testing\n' > "$h3/agent-config-status.yaml"
printf '# t\n' > "$a3/tasks/login.md"
bash "$reset" -ap "$a3" -cp "$h3" -t >/dev/null
if ! grep -q 'host-testing' "$h3/agent-config-status.yaml"; then
  echo 'expected status file untouched on tasks-only reset' >&2
  exit 1
fi

echo '== end-to-end: enable-test-on-host then reset clears host-testing state =='
a4="$tmpdir/a4/agent"
h4="$tmpdir/a4/helpers"
mkdir -p "$a4/instructions" "$h4"
printf 'Replace localhost with host.docker.internal.\n' > "$h4/extra-local.md"
printf 'allowed:\n  - http://localhost:8080\n' > "$a4/instructions/allowed-domains.yaml"
bash "$enable" -ap "$a4" -cp "$h4" >/dev/null
if ! grep -q 'host-testing' "$h4/agent-config-status.yaml"; then
  echo 'expected host-testing enabled before reset' >&2
  exit 1
fi
bash "$reset" -ap "$a4" -cp "$h4" -i >/dev/null
if [ -f "$h4/agent-config-status.yaml" ] && grep -q 'host-testing' "$h4/agent-config-status.yaml"; then
  echo 'expected host-testing state cleared after reset' >&2
  exit 1
fi

echo 'all checks passed'

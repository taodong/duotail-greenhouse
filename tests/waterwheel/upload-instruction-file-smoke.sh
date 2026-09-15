#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/upload-instruction-file.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

agent="$tmpdir/agent"
mkdir -p "$agent"

echo '== creates a file under instructions from stdin =='
printf 'allowed:\n  - http://host.docker.internal:8080\n' | bash "$script" -ap "$agent" allowed-domains.yaml
target="$agent/instructions/allowed-domains.yaml"
if [ ! -f "$target" ]; then
  echo 'expected instructions file to be created' >&2
  exit 1
fi
if ! grep -Fq 'http://host.docker.internal:8080' "$target"; then
  echo 'expected file content to match stdin' >&2
  exit 1
fi

echo '== replacing an existing file emits warning and updates content =='
replace_output=$(printf 'updated content\n' | bash "$script" -ap "$agent" allowed-domains.yaml 2>&1 >/dev/null)
printf '%s\n' "$replace_output" | grep -Fq 'WARNING: replacing existing file:'
if ! grep -Fq 'updated content' "$target"; then
  echo 'expected file content to be replaced' >&2
  exit 1
fi

echo '== a nested filename creates missing parent directories =='
printf 'note\n' | bash "$script" -ap "$agent" sub/dir/note.md
if [ ! -f "$agent/instructions/sub/dir/note.md" ]; then
  echo 'expected nested instructions file to be created' >&2
  exit 1
fi

echo '== missing filename fails with an error =='
if printf 'x\n' | bash "$script" -ap "$agent"; then
  echo 'expected missing-filename command to fail' >&2
  exit 1
fi

echo '== extra positional argument fails with an error =='
if printf 'x\n' | bash "$script" -ap "$agent" a b; then
  echo 'expected extra-argument command to fail' >&2
  exit 1
fi

echo '== unknown option fails with an error =='
if printf 'x\n' | bash "$script" -z name.txt; then
  echo 'expected unknown-option command to fail' >&2
  exit 1
fi

echo '== empty stdin is rejected, leaving a working config in place =='
printf '{"flow":[{"file":"test-2.md"}]}' | bash "$script" -ap "$agent" rerun-config.json > /dev/null
good=$(cat "$agent/instructions/rerun-config.json")
if printf '' | bash "$script" -ap "$agent" rerun-config.json 2>/dev/null; then
  echo 'expected empty stdin to be rejected' >&2
  exit 1
fi
if [ "$(cat "$agent/instructions/rerun-config.json")" != "$good" ]; then
  echo 'expected the existing config to survive' >&2
  exit 1
fi

echo '== the rejection carries no shell error of its own =='
# The lib's RETURN trap fires after its locals are out of scope. Unguarded,
# "$temp_file" is then an unbound variable under this script's "set -u" -- which
# only shows up when the lib is SOURCED, never when it is run directly.
reject_err=$(printf '' | bash "$script" -ap "$agent" rerun-config.json 2>&1 >/dev/null || true)
if printf '%s\n' "$reject_err" | grep -Fq 'unbound variable'; then
  echo "unexpected shell error on the rejection path: $reject_err" >&2
  exit 1
fi
if ! printf '%s\n' "$reject_err" | grep -Fq 'refusing to write empty content'; then
  echo 'expected the refusal message' >&2
  exit 1
fi

echo '== --allow-empty still permits a deliberate blank =='
printf '' | bash "$script" -ap "$agent" --allow-empty extra-instructions.md > /dev/null
if [ ! -f "$agent/instructions/extra-instructions.md" ] \
   || [ -s "$agent/instructions/extra-instructions.md" ]; then
  echo 'expected --allow-empty to write a zero-byte file' >&2
  exit 1
fi

echo '== help option prints usage =='
help_output=$(bash "$script" -h)
printf '%s\n' "$help_output" | grep -Fq 'Usage: upload-instruction-file.sh'

echo 'all checks passed'

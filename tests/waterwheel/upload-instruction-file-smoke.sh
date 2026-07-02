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

echo '== help option prints usage =='
help_output=$(bash "$script" -h)
printf '%s\n' "$help_output" | grep -Fq 'Usage: upload-instruction-file.sh'

echo 'all checks passed'

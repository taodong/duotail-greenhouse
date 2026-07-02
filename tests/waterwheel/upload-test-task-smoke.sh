#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/upload-test-task.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

agent="$tmpdir/agent"
mkdir -p "$agent"

echo '== creates a markdown task under tasks from stdin =='
printf '# Login test\n' | bash "$script" -ap "$agent" login.md
target="$agent/tasks/login.md"
if [ ! -f "$target" ]; then
  echo 'expected task file to be created' >&2
  exit 1
fi
if ! grep -Fq '# Login test' "$target"; then
  echo 'expected file content to match stdin' >&2
  exit 1
fi

echo '== replacing an existing task emits warning and updates content =='
replace_output=$(printf '# Updated\n' | bash "$script" -ap "$agent" login.md 2>&1 >/dev/null)
printf '%s\n' "$replace_output" | grep -Fq 'WARNING: replacing existing file:'
if ! grep -Fq '# Updated' "$target"; then
  echo 'expected file content to be replaced' >&2
  exit 1
fi

echo '== a nested filename creates missing parent directories =='
printf 'note\n' | bash "$script" -ap "$agent" suite/smoke.md
if [ ! -f "$agent/tasks/suite/smoke.md" ]; then
  echo 'expected nested task file to be created' >&2
  exit 1
fi

echo '== a non-md filename fails with an error =='
if printf 'x\n' | bash "$script" -ap "$agent" notes.txt; then
  echo 'expected non-md command to fail' >&2
  exit 1
fi

echo '== missing filename fails with an error =='
if printf 'x\n' | bash "$script" -ap "$agent"; then
  echo 'expected missing-filename command to fail' >&2
  exit 1
fi

echo '== extra positional argument fails with an error =='
if printf 'x\n' | bash "$script" -ap "$agent" a.md b.md; then
  echo 'expected extra-argument command to fail' >&2
  exit 1
fi

echo '== unknown option fails with an error =='
if printf 'x\n' | bash "$script" -z name.md; then
  echo 'expected unknown-option command to fail' >&2
  exit 1
fi

echo '== help option prints usage =='
help_output=$(bash "$script" -h)
printf '%s\n' "$help_output" | grep -Fq 'Usage: upload-test-task.sh'

echo 'all checks passed'

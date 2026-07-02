#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/set-domain-permission.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

agent="$tmpdir/agent"
mkdir -p "$agent/instructions"
target="$agent/instructions/allowed-domains.yaml"

echo '== generates allowed-domains.yaml from a comma-delimited list =='
bash "$script" -ap "$agent" 'https://www.google.com,https://*.wikipedia.org,http://localhost:8080'
expected=$'allowed:\n  - https://www.google.com\n  - https://*.wikipedia.org\n  - http://localhost:8080'
if [ "$(cat "$target")" != "$expected" ]; then
  echo 'unexpected yaml output without -l' >&2
  cat "$target" >&2
  exit 1
fi

echo '== -l rewrites localhost to host.docker.internal =='
bash "$script" -ap "$agent" -l 'https://www.google.com,https://*.wikipedia.org,http://localhost:8080'
expected_l=$'allowed:\n  - https://www.google.com\n  - https://*.wikipedia.org\n  - http://host.docker.internal:8080'
if [ "$(cat "$target")" != "$expected_l" ]; then
  echo 'unexpected yaml output with -l' >&2
  cat "$target" >&2
  exit 1
fi

echo '== trims whitespace and ignores empty entries =='
bash "$script" -ap "$agent" '  https://a.com ,  , http://localhost:9 ,'
expected_trim=$'allowed:\n  - https://a.com\n  - http://localhost:9'
if [ "$(cat "$target")" != "$expected_trim" ]; then
  echo 'unexpected yaml output for whitespace/empty case' >&2
  cat "$target" >&2
  exit 1
fi

echo '== no domains fails with an error =='
if bash "$script" -ap "$agent"; then
  echo 'expected missing-domains command to fail' >&2
  exit 1
fi

echo '== only empty entries fails with an error =='
if bash "$script" -ap "$agent" ' , , '; then
  echo 'expected empty-entries command to fail' >&2
  exit 1
fi

echo '== missing instructions directory fails with an error =='
if bash "$script" -ap "$tmpdir/missing-agent" 'https://a.com'; then
  echo 'expected missing-directory command to fail' >&2
  exit 1
fi

echo '== unknown option fails with an error =='
if bash "$script" -x 'https://a.com'; then
  echo 'expected unknown-option command to fail' >&2
  exit 1
fi

echo '== help option prints usage =='
help_output=$(bash "$script" -h)
printf '%s\n' "$help_output" | grep -Fq 'Usage: set-domain-permission.sh'

echo 'all checks passed'

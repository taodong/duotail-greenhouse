#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/customize-playwright-config.sh"
template_src="$repo/waterwheel/files/bootstrap/playwright-mcp-config-default.json"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

agent="$tmpdir/agent"
helpers="$tmpdir/config-helpers"
mkdir -p "$agent/instructions" "$helpers"
cp "$template_src" "$helpers/playwright-mcp-config-default.json"
target="$agent/instructions/playwright-mcp-config.json"

echo '== --treat-as-secure writes config with secure-context args =='
bash "$script" -ap "$agent" -cp "$helpers" \
  --treat-as-secure 'http://host.docker.internal:8080,http://host.docker.internal:8081'

if [[ ! -f "$target" ]]; then
  echo "Error: target file was not created" >&2
  exit 1
fi

actual_arg=$(jq -r '.browser.launchOptions.args[] | select(startswith("--unsafely-treat-insecure-origin-as-secure="))' "$target")
expected_arg="--unsafely-treat-insecure-origin-as-secure=http://host.docker.internal:8080,http://host.docker.internal:8081"
if [[ "$actual_arg" != "$expected_arg" ]]; then
  echo "Error: unexpected --unsafely-treat-insecure-origin-as-secure value: $actual_arg" >&2
  exit 1
fi

if ! jq -e '.browser.launchOptions.args[] | select(. == "--ignore-certificate-errors")' "$target" > /dev/null; then
  echo "Error: --ignore-certificate-errors not found in args" >&2
  cat "$target" >&2
  exit 1
fi

if ! jq -e '.browser.launchOptions.args[] | select(. == "--disable-gpu")' "$target" > /dev/null; then
  echo "Error: --disable-gpu not preserved from template" >&2
  cat "$target" >&2
  exit 1
fi

echo '== --treat-as-secure replaces existing secure-context args (replace-only) =='
bash "$script" -ap "$agent" -cp "$helpers" \
  --treat-as-secure 'http://host.docker.internal:9090'

actual_arg=$(jq -r '.browser.launchOptions.args[] | select(startswith("--unsafely-treat-insecure-origin-as-secure="))' "$target")
if [[ "$actual_arg" != "--unsafely-treat-insecure-origin-as-secure=http://host.docker.internal:9090" ]]; then
  echo "Error: replace did not update the arg; got: $actual_arg" >&2
  exit 1
fi

count=$(jq '[.browser.launchOptions.args[] | select(startswith("--unsafely-treat-insecure-origin-as-secure="))] | length' "$target")
if [[ "$count" -ne 1 ]]; then
  echo "Error: expected exactly one --unsafely-treat-insecure-origin-as-secure arg, got $count" >&2
  exit 1
fi

echo '== --clear removes the config file =='
bash "$script" -ap "$agent" -cp "$helpers" --clear
if [[ -f "$target" ]]; then
  echo "Error: target file was not removed by --clear" >&2
  exit 1
fi

echo '== --clear is a no-op when file does not exist =='
bash "$script" -ap "$agent" -cp "$helpers" --clear

echo '== --clear cannot be combined with --treat-as-secure =='
if bash "$script" -ap "$agent" -cp "$helpers" \
    --clear --treat-as-secure 'http://host.docker.internal:8080'; then
  echo "Error: expected combined --clear/--treat-as-secure to fail" >&2
  exit 1
fi

echo '== no operation fails with an error =='
if bash "$script" -ap "$agent" -cp "$helpers"; then
  echo "Error: expected no-operation invocation to fail" >&2
  exit 1
fi

echo '== missing instructions directory fails with an error =='
if bash "$script" -ap "$tmpdir/missing" -cp "$helpers" \
    --treat-as-secure 'http://host.docker.internal:8080'; then
  echo "Error: expected missing-directory invocation to fail" >&2
  exit 1
fi

echo '== missing template fails with an error =='
if bash "$script" -ap "$agent" -cp "$tmpdir/missing-helpers" \
    --treat-as-secure 'http://host.docker.internal:8080'; then
  echo "Error: expected missing-template invocation to fail" >&2
  exit 1
fi

echo '== unknown option fails with an error =='
if bash "$script" --unknown-opt 'foo'; then
  echo "Error: expected unknown option to fail" >&2
  exit 1
fi

echo '== help option prints usage =='
help_output=$(bash "$script" --help)
printf '%s\n' "$help_output" | grep -Fq 'Usage:'

echo 'all checks passed'

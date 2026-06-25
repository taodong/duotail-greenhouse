#!/usr/bin/env bash
set -euo pipefail

repo=/Users/taodong/Work/code/duotail-greenhouse
lib="$repo/waterwheel/files/scripts/file-upload-lib.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

echo '== writes stdin content to target file and creates missing parent folders =='
target="$tmpdir/nested/path/output.txt"
printf 'hello upload\n' | bash "$lib" "$target"
if [ ! -f "$target" ]; then
  echo 'expected target file to be created' >&2
  exit 1
fi
if ! grep -Fq 'hello upload' "$target"; then
  echo 'expected target content to match stdin' >&2
  exit 1
fi

echo '== replacing existing file emits warning and updates content =='
replace_output=$(printf 'updated value\n' | bash "$lib" "$target" 2>&1 >/dev/null)
printf '%s\n' "$replace_output"
printf '%s\n' "$replace_output" | grep -Fq 'WARNING: replacing existing file:'
if ! grep -Fq 'updated value' "$target"; then
  echo 'expected file content to be replaced' >&2
  exit 1
fi

echo '== relative path is rejected with an error =='
if printf 'bad path\n' | bash "$lib" "relative/output.txt"; then
  echo 'expected relative path command to fail' >&2
  exit 1
fi

echo '== missing path argument fails with error =='
if printf 'missing path\n' | bash "$lib"; then
  echo 'expected missing path command to fail' >&2
  exit 1
fi

echo '== help option prints usage =='
help_output=$(bash "$lib" --help)
printf '%s\n' "$help_output"
printf '%s\n' "$help_output" | grep -Fq 'Usage: file-upload-lib <absolute-path>'

echo 'all checks passed'


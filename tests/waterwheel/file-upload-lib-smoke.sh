#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

echo '== empty stdin is rejected and leaves the existing file untouched =='
# A producing command that fails writes nothing and exits non-zero, but a
# pipeline reports its LAST command's status -- so without this guard an
# upstream failure silently installed a zero-byte file over a working one.
before=$(cat "$target")
if printf '' | bash "$lib" "$target" 2>/dev/null; then
  echo 'expected empty stdin to be rejected' >&2
  exit 1
fi
if [ "$(cat "$target")" != "$before" ]; then
  echo 'expected the existing file to be left untouched' >&2
  exit 1
fi

echo '== the rejection names the file and says nothing was changed =='
empty_err=$(printf '' | bash "$lib" "$target" 2>&1 >/dev/null || true)
printf '%s\n' "$empty_err" | grep -Fq 'refusing to write empty content' \
  || { echo 'expected the refusal message' >&2; exit 1; }
printf '%s\n' "$empty_err" | grep -Fq 'existing file is unchanged' \
  || { echo 'expected reassurance that the file survived' >&2; exit 1; }
echo '== a rejected upload leaves no temp file behind =='
leftover=$(find "$(dirname "$target")" -maxdepth 1 -name '*.tmp.*' -print -quit)
if [ -n "$leftover" ]; then
  echo "expected no leftover temp file, found: $leftover" >&2
  exit 1
fi

echo '== --allow-empty writes a zero-byte file on purpose =='
blank="$tmpdir/blank.txt"
printf '' | bash "$lib" --allow-empty "$blank"
if [ ! -f "$blank" ] || [ -s "$blank" ]; then
  echo 'expected an empty file to be created' >&2
  exit 1
fi

echo '== empty stdin does not create a new file either =='
never="$tmpdir/never-created.txt"
if printf '' | bash "$lib" "$never" 2>/dev/null; then
  echo 'expected empty stdin to be rejected for a new file too' >&2
  exit 1
fi
if [ -e "$never" ]; then
  echo 'expected no file to be created' >&2
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
printf '%s\n' "$help_output" | grep -Fq 'Usage: file-upload-lib [--allow-empty] <absolute-path>'

echo 'all checks passed'


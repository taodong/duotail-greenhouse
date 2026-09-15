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

echo '== a rejected upload rolls back only the directories it created =='
nested="$tmpdir/existing/made/deeper/out.txt"
mkdir -p "$tmpdir/existing"
if printf '' | bash "$lib" "$nested" 2>/dev/null; then
  echo 'expected empty stdin to be rejected' >&2
  exit 1
fi
if [ -e "$tmpdir/existing/made" ]; then
  echo 'expected the created directories to be rolled back' >&2
  exit 1
fi
if [ ! -d "$tmpdir/existing" ]; then
  echo 'expected the pre-existing ancestor to survive' >&2
  exit 1
fi

echo '== rollback never removes a directory holding other content =='
sibling="$tmpdir/shared/out.txt"
mkdir -p "$tmpdir/shared"
printf 'keep me\n' > "$tmpdir/shared/other.txt"
if printf '' | bash "$lib" "$sibling" 2>/dev/null; then
  echo 'expected empty stdin to be rejected' >&2
  exit 1
fi
if [ ! -f "$tmpdir/shared/other.txt" ]; then
  echo 'expected unrelated content to survive' >&2
  exit 1
fi

echo '== rollback refuses a directory that is not empty =='
# rmdir, not "rm -r": if anything landed inside a directory this upload created,
# the rollback leaves it alone. Exercised against the helper directly -- reaching
# that state through the CLI would take a concurrent writer.
# shellcheck disable=SC1090
source "$lib"
mkdir -p "$tmpdir/rb/created"
printf 'x\n' > "$tmpdir/rb/created/unexpected.txt"
file_upload_rollback_dirs "$tmpdir/rb/created" "$tmpdir/rb/created"
if [ ! -f "$tmpdir/rb/created/unexpected.txt" ]; then
  echo 'expected rollback to refuse a non-empty directory' >&2
  exit 1
fi

echo '== rollback is a no-op when the upload created nothing =='
mkdir -p "$tmpdir/rb/untouched"
file_upload_rollback_dirs "$tmpdir/rb/untouched" ""
if [ ! -d "$tmpdir/rb/untouched" ]; then
  echo 'expected no rollback without a recorded created root' >&2
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


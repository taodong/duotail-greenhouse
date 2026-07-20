#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/delete-test-skills.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

agent="$tmpdir/agent"

seed_skill() {
  local root="$1" name="$2"
  mkdir -p "$root/$name"
  printf '# %s\n' "$name" > "$root/$name/SKILL.md"
}

echo '== deletes a single matching skill folder =='
seed_skill "$agent/skills" login-flow
bash "$script" -ap "$agent" -names login-flow
if [ -d "$agent/skills/login-flow" ]; then
  echo 'expected skill folder to be removed' >&2
  exit 1
fi

echo '== deletes multiple comma-delimited skills and skips missing ones =='
seed_skill "$agent/skills" login-flow
seed_skill "$agent/skills" checkout
seed_skill "$agent/skills" keep
out=$(bash "$script" -ap "$agent" -names 'login-flow, checkout, missing' 2>&1)
if [ -d "$agent/skills/login-flow" ] || [ -d "$agent/skills/checkout" ]; then
  echo 'expected matched skill folders to be removed' >&2
  exit 1
fi
if [ ! -d "$agent/skills/keep" ]; then
  echo 'expected unmatched skill folder to be preserved' >&2
  exit 1
fi
printf '%s\n' "$out" | grep -Fq 'No matching skill folder: missing'
printf '%s\n' "$out" | grep -Fq 'Deleted 2 skill(s), skipped 1.'

echo '== SKILL_DIR overrides the default skills location =='
seed_skill "$tmpdir/customskills" foo
SKILL_DIR="$tmpdir/customskills" bash "$script" -names foo
if [ -d "$tmpdir/customskills/foo" ]; then
  echo 'expected SKILL_DIR to be honored' >&2
  exit 1
fi

echo '== deleting a non-existent skill exits 0 and reports it =='
out=$(bash "$script" -ap "$agent" -names ghost 2>&1)
printf '%s\n' "$out" | grep -Fq 'No matching skill folder: ghost'
printf '%s\n' "$out" | grep -Fq 'Deleted 0 skill(s), skipped 1.'

echo '== missing -names fails with an error =='
if bash "$script" -ap "$agent"; then
  echo 'expected missing-names command to fail' >&2
  exit 1
fi

echo '== a skill name with a path separator fails with an error =='
if bash "$script" -ap "$agent" -names ../evil; then
  echo 'expected path-separator name to fail' >&2
  exit 1
fi

echo '== a "." skill name fails with an error =='
if bash "$script" -ap "$agent" -names .; then
  echo 'expected "." name to fail' >&2
  exit 1
fi

echo '== traversal in a comma-delimited list fails before deleting =='
seed_skill "$agent/skills" safe
if bash "$script" -ap "$agent" -names 'safe,../evil'; then
  echo 'expected traversal name to fail' >&2
  exit 1
fi

echo '== extra positional argument fails with an error =='
if bash "$script" -ap "$agent" -names a b; then
  echo 'expected extra-argument command to fail' >&2
  exit 1
fi

echo '== unknown option fails with an error =='
if bash "$script" -z -names name; then
  echo 'expected unknown-option command to fail' >&2
  exit 1
fi

echo '== help option prints usage =='
help_output=$(bash "$script" -h)
printf '%s\n' "$help_output" | grep -Fq 'Usage: delete-test-skills.sh'

echo 'all checks passed'

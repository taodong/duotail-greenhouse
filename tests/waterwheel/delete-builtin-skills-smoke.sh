#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/delete-builtin-skills.sh"
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

echo '== deletes a single matching built-in skill folder =='
seed_skill "$agent/builtin-skills" login-flow
bash "$script" -ap "$agent" -n login-flow
if [ -d "$agent/builtin-skills/login-flow" ]; then
  echo 'expected skill folder to be removed' >&2
  exit 1
fi

echo '== deletes multiple comma-delimited skills and skips missing ones =='
seed_skill "$agent/builtin-skills" login-flow
seed_skill "$agent/builtin-skills" checkout
seed_skill "$agent/builtin-skills" keep
out=$(bash "$script" -ap "$agent" -n 'login-flow, checkout, missing' 2>&1)
if [ -d "$agent/builtin-skills/login-flow" ] || [ -d "$agent/builtin-skills/checkout" ]; then
  echo 'expected matched skill folders to be removed' >&2
  exit 1
fi
if [ ! -d "$agent/builtin-skills/keep" ]; then
  echo 'expected unmatched skill folder to be preserved' >&2
  exit 1
fi
printf '%s\n' "$out" | grep -Fq 'No matching skill folder: missing'
printf '%s\n' "$out" | grep -Fq 'Deleted 2 skill(s), skipped 1.'

echo '== --names is an alias for -n =='
seed_skill "$agent/builtin-skills" via-long
bash "$script" -ap "$agent" --names via-long
if [ -d "$agent/builtin-skills/via-long" ]; then
  echo 'expected --names to remove the skill folder' >&2
  exit 1
fi

echo '== a "ww:" prefix targets the unprefixed skill =='
seed_skill "$agent/builtin-skills" alpha
bash "$script" -ap "$agent" -n ww:alpha
if [ -d "$agent/builtin-skills/alpha" ]; then
  echo 'expected ww:-prefixed name to remove alpha' >&2
  exit 1
fi

echo '== "ww:" prefix works within a comma-delimited list =='
seed_skill "$agent/builtin-skills" alpha
seed_skill "$agent/builtin-skills" beta
out=$(bash "$script" -ap "$agent" -n 'ww:alpha,beta' 2>&1)
if [ -d "$agent/builtin-skills/alpha" ] || [ -d "$agent/builtin-skills/beta" ]; then
  echo 'expected both alpha and beta to be removed' >&2
  exit 1
fi
printf '%s\n' "$out" | grep -Fq 'Deleted 2 skill(s), skipped 0.'

echo '== "ww: foo" with a space after the prefix targets foo =='
seed_skill "$agent/builtin-skills" foo
bash "$script" -ap "$agent" -n 'ww: foo'
if [ -d "$agent/builtin-skills/foo" ]; then
  echo 'expected "ww: foo" to remove foo' >&2
  exit 1
fi

echo '== deleting a non-existent skill exits 0 and reports it =='
out=$(bash "$script" -ap "$agent" -n ghost 2>&1)
printf '%s\n' "$out" | grep -Fq 'No matching skill folder: ghost'
printf '%s\n' "$out" | grep -Fq 'Deleted 0 skill(s), skipped 1.'

echo '== missing -n fails with an error =='
if bash "$script" -ap "$agent"; then
  echo 'expected missing-names command to fail' >&2
  exit 1
fi

echo '== a skill name with a path separator fails with an error =='
if bash "$script" -ap "$agent" -n ../evil; then
  echo 'expected path-separator name to fail' >&2
  exit 1
fi

echo '== a "." skill name fails with an error =='
if bash "$script" -ap "$agent" -n .; then
  echo 'expected "." name to fail' >&2
  exit 1
fi

echo '== a "ww:"-prefixed traversal name still fails with an error =='
seed_skill "$agent/builtin-skills" safe
if bash "$script" -ap "$agent" -n 'safe,ww:../evil'; then
  echo 'expected ww:-prefixed traversal name to fail' >&2
  exit 1
fi
if [ ! -d "$agent/builtin-skills/safe" ]; then
  echo 'expected no deletions when input contains an invalid skill name' >&2
  exit 1
fi

echo '== traversal in a comma-delimited list fails before deleting =='
if bash "$script" -ap "$agent" -n 'safe,../evil'; then
  echo 'expected traversal name to fail' >&2
  exit 1
fi
if [ ! -d "$agent/builtin-skills/safe" ]; then
  echo 'expected no deletions when input contains an invalid skill name' >&2
  exit 1
fi

echo '== extra positional argument fails with an error =='
if bash "$script" -ap "$agent" -n a b; then
  echo 'expected extra-argument command to fail' >&2
  exit 1
fi

echo '== unknown option fails with an error =='
if bash "$script" -z -n name; then
  echo 'expected unknown-option command to fail' >&2
  exit 1
fi

echo '== help option prints usage =='
help_output=$(bash "$script" -h)
printf '%s\n' "$help_output" | grep -Fq 'Usage: delete-builtin-skills.sh'

echo 'all checks passed'

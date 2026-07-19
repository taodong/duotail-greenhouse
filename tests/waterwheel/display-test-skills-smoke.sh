#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/display-test-skills.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

agent="$tmpdir/agent"
mkdir -p "$agent/builtin-skills/alpha" "$agent/builtin-skills/beta" "$agent/skills/gamma"
printf '# Alpha\nbuiltin alpha content\n' > "$agent/builtin-skills/alpha/SKILL.md"
printf '# Beta\nbuiltin beta content\n' > "$agent/builtin-skills/beta/SKILL.md"
printf '# Gamma\nuser gamma content\n' > "$agent/skills/gamma/SKILL.md"

echo '== lists both built-in and user skills =='
list_output=$(bash "$script" -ap "$agent")
printf '%s\n' "$list_output" | grep -Fq 'alpha (built-in)'
printf '%s\n' "$list_output" | grep -Fq 'beta (built-in)'
if ! printf '%s\n' "$list_output" | grep -Eq '^gamma$'; then
  echo 'expected user skill gamma listed without a built-in marker' >&2
  exit 1
fi

echo '== user skills are not marked as built-in =='
if printf '%s\n' "$list_output" | grep -Fq 'gamma (built-in)'; then
  echo 'expected user skill not to be marked built-in' >&2
  exit 1
fi

echo '== --show prints a built-in SKILL.md =='
show_builtin=$(bash "$script" -ap "$agent" --show alpha)
printf '%s\n' "$show_builtin" | grep -Fq 'builtin alpha content'

echo '== -s short flag prints a user SKILL.md =='
show_user=$(bash "$script" -ap "$agent" -s gamma)
printf '%s\n' "$show_user" | grep -Fq 'user gamma content'

echo '== a user skill shadows a built-in of the same name =='
mkdir -p "$agent/builtin-skills/dup" "$agent/skills/dup"
printf 'builtin dup\n' > "$agent/builtin-skills/dup/SKILL.md"
printf 'user dup\n' > "$agent/skills/dup/SKILL.md"
show_dup=$(bash "$script" -ap "$agent" --show dup)
if ! printf '%s\n' "$show_dup" | grep -Fq 'user dup'; then
  echo 'expected user skill to take precedence over built-in' >&2
  exit 1
fi
if printf '%s\n' "$show_dup" | grep -Fq 'builtin dup'; then
  echo 'expected built-in not to be printed when a user skill exists' >&2
  exit 1
fi

echo '== --show for a missing skill reports no match =='
missing_output=$(bash "$script" -ap "$agent" --show nope)
printf '%s\n' "$missing_output" | grep -Fq 'No skill is matched.'

echo '== empty install reports no skills =='
empty_agent="$tmpdir/empty"
mkdir -p "$empty_agent"
empty_output=$(bash "$script" -ap "$empty_agent")
printf '%s\n' "$empty_output" | grep -Fq 'No skills installed.'

echo '== --show requires a skill name =='
if bash "$script" -ap "$agent" --show; then
  echo 'expected --show without a value to fail' >&2
  exit 1
fi

echo '== a skill name with a path separator fails with an error =='
if bash "$script" -ap "$agent" --show ../evil; then
  echo 'expected path-separator name to fail' >&2
  exit 1
fi

echo '== unknown option fails with an error =='
if bash "$script" -ap "$agent" -z; then
  echo 'expected unknown-option command to fail' >&2
  exit 1
fi

echo '== unexpected positional argument fails with an error =='
if bash "$script" -ap "$agent" extra; then
  echo 'expected unexpected-argument command to fail' >&2
  exit 1
fi

echo '== help option prints usage =='
help_output=$(bash "$script" -h)
printf '%s\n' "$help_output" | grep -Fq 'Usage: display-test-skills.sh'

echo 'all checks passed'

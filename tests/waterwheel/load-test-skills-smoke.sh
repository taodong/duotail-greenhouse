#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/load-test-skills.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

agent="$tmpdir/agent"
mkdir -p "$agent"

echo '== creates a skill folder with SKILL.md from stdin =='
printf '# Login flow\nSteps here\n' | bash "$script" -ap "$agent" -name login-flow
target="$agent/skills/login-flow/SKILL.md"
if [ ! -d "$agent/skills/login-flow" ]; then
  echo 'expected skill folder to be created' >&2
  exit 1
fi
if [ ! -f "$target" ]; then
  echo 'expected SKILL.md to be created' >&2
  exit 1
fi
if ! grep -Fq '# Login flow' "$target"; then
  echo 'expected SKILL.md content to match stdin' >&2
  exit 1
fi

echo '== an existing skill folder is skipped without --force =='
skip_output=$(printf 'SHOULD NOT WIN\n' | bash "$script" -ap "$agent" -name login-flow 2>&1)
printf '%s\n' "$skip_output" | grep -Fq 'Skipping existing skill folder:'
if ! grep -Fq '# Login flow' "$target"; then
  echo 'expected existing SKILL.md to be left untouched' >&2
  exit 1
fi
if grep -Fq 'SHOULD NOT WIN' "$target"; then
  echo 'expected skipped run not to overwrite SKILL.md' >&2
  exit 1
fi

echo '== --force overwrites an existing skill folder =='
printf '# Login flow v2\n' | bash "$script" -ap "$agent" -name login-flow --force
if ! grep -Fq '# Login flow v2' "$target"; then
  echo 'expected --force to replace SKILL.md content' >&2
  exit 1
fi

echo '== -f short flag also overwrites =='
printf '# Login flow v3\n' | bash "$script" -ap "$agent" -name login-flow -f
if ! grep -Fq '# Login flow v3' "$target"; then
  echo 'expected -f to replace SKILL.md content' >&2
  exit 1
fi

echo '== SKILLS_DIR overrides the default skills location =='
printf '# other\n' | SKILLS_DIR="$tmpdir/customskills" bash "$script" -name foo
if [ ! -f "$tmpdir/customskills/foo/SKILL.md" ]; then
  echo 'expected SKILLS_DIR to be honored' >&2
  exit 1
fi

echo '== missing skill name fails with an error =='
if printf 'x\n' | bash "$script" -ap "$agent"; then
  echo 'expected missing-name command to fail' >&2
  exit 1
fi

echo '== a skill name with a path separator fails with an error =='
if printf 'x\n' | bash "$script" -ap "$agent" -name ../evil; then
  echo 'expected path-separator name to fail' >&2
  exit 1
fi

echo '== a "." skill name fails with an error =='
if printf 'x\n' | bash "$script" -ap "$agent" -name .; then
  echo 'expected "." name to fail' >&2
  exit 1
fi

echo '== extra positional argument fails with an error =='
if printf 'x\n' | bash "$script" -ap "$agent" -name a b; then
  echo 'expected extra-argument command to fail' >&2
  exit 1
fi

echo '== unknown option fails with an error =='
if printf 'x\n' | bash "$script" -z -name name; then
  echo 'expected unknown-option command to fail' >&2
  exit 1
fi

echo '== help option prints usage =='
help_output=$(bash "$script" -h)
printf '%s\n' "$help_output" | grep -Fq 'Usage: load-test-skills.sh'

echo 'all checks passed'

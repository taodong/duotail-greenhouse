#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scripts="$repo/waterwheel/files/scripts"
tmpdir=$(mktemp -d)
agent="$tmpdir/agent"
mkdir -p "$agent/instructions"

echo '== manage-global-constants nested set/list =='
bash "$scripts/manage-global-constants.sh" -ap "$agent" set user.name=qa
bash "$scripts/manage-global-constants.sh" -ap "$agent" list >/dev/null

echo '== preset variables set =='
bash "$scripts/preset-context.sh" -ap "$agent" variables set username=admin

echo '== flow import with extra keys =='
cat > "$tmpdir/flow-extra.json" <<'EOF'
{"flow":[{"file":"login.md","node":1}],"data":{"ignored":true},"notes":"ignored"}
EOF
bash "$scripts/preset-context.sh" -ap "$agent" flow "$tmpdir/flow-extra.json"

echo '== flow clear keeps data =='
bash "$scripts/preset-context.sh" -ap "$agent" flow clear
jq -e '(.data.username == "admin") and ((.flow // []) | length == 0)' "$agent/instructions/preset-context.json" >/dev/null

echo '== flow clear removes file when data empty =='
cat > "$agent/instructions/preset-context.json" <<'EOF'
{"flow":[{"file":"a.md"}]}
EOF
bash "$scripts/preset-context.sh" -ap "$agent" flow clear
[ ! -f "$agent/instructions/preset-context.json" ]

echo '== mixed invocation rejected =='
if bash "$scripts/preset-context.sh" -ap "$agent" flow clear variables set foo=bar; then
  echo 'expected mixed invocation to fail' >&2
  exit 1
fi

echo 'all checks passed'


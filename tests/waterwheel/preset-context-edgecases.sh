#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scripts="$repo/waterwheel/files/scripts"
tmpdir=$(mktemp -d)
agent="$tmpdir/agent"
mkdir -p "$agent/instructions"

echo '== delete last variable removes file =='
bash "$scripts/preset-context.sh" -ap "$agent" variables set only=value
bash "$scripts/preset-context.sh" -ap "$agent" variables delete only
if [ -f "$agent/instructions/preset-context.json" ]; then
  echo 'expected preset-context.json to be removed' >&2
  exit 1
fi

echo '== raw-array flow file is rejected =='
raw_flow="$tmpdir/raw-flow.json"
cat > "$raw_flow" <<'EOF'
[]
EOF
if bash "$scripts/preset-context.sh" -ap "$agent" flow "$raw_flow"; then
  echo 'unexpected success importing raw array flow' >&2
  exit 1
else
  echo 'raw-array flow rejected as expected'
fi


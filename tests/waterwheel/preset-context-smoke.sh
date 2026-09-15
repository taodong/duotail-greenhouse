#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scripts="$repo/waterwheel/files/scripts"
tmpdir=$(mktemp -d)
agent="$tmpdir/agent"
mkdir -p "$agent/instructions"
flow_file="$tmpdir/flow.json"
cat > "$flow_file" <<'EOF'
{"flow":[{"file":"login.md","node":1},{"file":"checkout.md","required":[1],"ignore":false}]}
EOF

echo '== preset-context variables set =='
bash "$scripts/preset-context.sh" -ap "$agent" variables set username=admin,user.password=secret

echo '== preset-context variables list =='
bash "$scripts/preset-context.sh" -ap "$agent" variables list

echo '== preset-context flow import =='
bash "$scripts/preset-context.sh" -ap "$agent" flow "$flow_file"

echo '== preset-context after flow import =='
cat "$agent/instructions/preset-context.json"

echo '== preset-context variables clear =='
bash "$scripts/preset-context.sh" -ap "$agent" variables clear

echo '== preset-context after clear =='
cat "$agent/instructions/preset-context.json"

echo '== mixed command should fail =='
if bash "$scripts/preset-context.sh" -ap "$agent" flow "$flow_file" variables set foo=bar; then
  echo 'unexpected success' >&2
  exit 1
else
  echo 'mixed command failed as expected'
fi

echo '== global constants nested set =='
bash "$scripts/manage-global-constants.sh" -ap "$agent" set user.name=qa,user.password=secret

echo '== global constants list =='
bash "$scripts/manage-global-constants.sh" -ap "$agent" list

echo '== global constants delete nested =='
bash "$scripts/manage-global-constants.sh" -ap "$agent" delete user.name

echo '== global constants after delete =='
bash "$scripts/manage-global-constants.sh" -ap "$agent" list


# A failing setpath must leave the target file alone. jq fails whenever a dotted
# key collides with an existing non-object value, or the file already holds
# malformed JSON. When that failure went unchecked, cmd_set wrote an empty
# document over a good file and still reported "Updated", exiting 0.
echo '== a colliding dotted key leaves the file unchanged =='
printf '{"BASE_URL":"https://x","user":"ada"}' > "$agent/instructions/global-context.json"
before=$(cat "$agent/instructions/global-context.json")
if bash "$scripts/manage-global-constants.sh" -ap "$agent" set 'user.name=Ada' 2>/dev/null; then
  echo 'expected a colliding dotted key to fail' >&2
  exit 1
fi
after=$(cat "$agent/instructions/global-context.json")
if [ "$before" != "$after" ]; then
  echo "expected the file to be untouched, got: $after" >&2
  exit 1
fi
echo 'file preserved as expected'

echo '== a malformed target file is not overwritten =='
printf 'not json' > "$agent/instructions/global-context.json"
if bash "$scripts/manage-global-constants.sh" -ap "$agent" set 'A=1' 2>/dev/null; then
  echo 'expected a malformed target file to fail' >&2
  exit 1
fi
if [ "$(cat "$agent/instructions/global-context.json")" != 'not json' ]; then
  echo 'expected the malformed file to be left alone' >&2
  exit 1
fi
echo 'malformed file preserved as expected'

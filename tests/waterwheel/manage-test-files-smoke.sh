#!/usr/bin/env bash
set -euo pipefail

repo=/Users/taodong/Work/code/duotail-greenhouse
scripts="$repo/waterwheel/files/scripts"
tmpdir=$(mktemp -d)
agent="$tmpdir/agent"
mkdir -p "$agent/tasks"

src="$tmpdir/src"
mkdir -p "$src/dir/sub"

cat > "$src/a.md" <<'EOF'
# A
EOF

cat > "$src/b.txt" <<'EOF'
not markdown
EOF

cat > "$src/dir/c.md" <<'EOF'
# C
EOF

cat > "$src/dir/d.txt" <<'EOF'
not markdown
EOF

cat > "$src/dir/sub/e.md" <<'EOF'
# E
EOF

echo '== add file + directory; non-md and nested files are ignored =='
bash "$scripts/manage-test-files.sh" -ap "$agent" add "$src/a.md,$src/dir,$src/missing.md,$src/b.txt"

if [ ! -f "$agent/tasks/a.md" ]; then
  echo 'expected a.md in tasks' >&2
  exit 1
fi
if [ ! -f "$agent/tasks/c.md" ]; then
  echo 'expected c.md in tasks' >&2
  exit 1
fi
if [ -f "$agent/tasks/e.md" ]; then
  echo 'did not expect nested e.md in tasks' >&2
  exit 1
fi
if [ -f "$agent/tasks/b.txt" ]; then
  echo 'did not expect b.txt in tasks' >&2
  exit 1
fi

echo '== list returns markdown files with indexes =='
list_out=$(bash "$scripts/manage-test-files.sh" -ap "$agent" list)
printf '%s\n' "$list_out"
printf '%s\n' "$list_out" | grep -Eq '^1\. .+\.md$'
printf '%s\n' "$list_out" | grep -Eq '^2\. .+\.md$'

echo '== delete by filename and index, best effort for invalid selectors =='
bash "$scripts/manage-test-files.sh" -ap "$agent" delete "a.md,999,missing.md,2"

if [ -f "$agent/tasks/a.md" ]; then
  echo 'expected a.md to be deleted' >&2
  exit 1
fi
if [ -f "$agent/tasks/c.md" ]; then
  echo 'expected c.md to be deleted' >&2
  exit 1
fi

echo '== silent overwrite by basename =='
cat > "$src/dir/a.md" <<'EOF'
# A NEW
EOF
bash "$scripts/manage-test-files.sh" -ap "$agent" add "$src/dir/a.md"
grep -q 'A NEW' "$agent/tasks/a.md"

echo '== clear removes only markdown files =='
touch "$agent/tasks/keep.json"
bash "$scripts/manage-test-files.sh" -ap "$agent" clear
if [ -f "$agent/tasks/a.md" ]; then
  echo 'expected markdown files to be cleared' >&2
  exit 1
fi
if [ ! -f "$agent/tasks/keep.json" ]; then
  echo 'expected non-markdown file to remain' >&2
  exit 1
fi

echo 'all checks passed'



#!/usr/bin/env bash
set -euo pipefail

# Covers the launch arguments in playwright-mcp. --isolated is what stops a login
# from one run reaching the next, so dropping it must fail here. npm and node are
# stubbed, so no browser or container is needed.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/playwright-mcp.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/npm-root/@playwright/mcp"
touch "$tmpdir/npm-root/@playwright/mcp/cli.js"

cat > "$tmpdir/bin/npm" <<EOF
#!/usr/bin/env bash
echo "$tmpdir/npm-root"
EOF

cat > "$tmpdir/bin/node" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$tmpdir/node-args"
EOF

chmod +x "$tmpdir/bin/npm" "$tmpdir/bin/node"

PATH="$tmpdir/bin:$PATH" PLAYWRIGHT_MCP_VERSION=0.0.0 FIREWALL_DEBUG=false \
  bash "$script" >/dev/null 2>&1

[ -f "$tmpdir/node-args" ] || { echo 'playwright-mcp did not launch the MCP' >&2; exit 1; }

grep -qx -- '--isolated' "$tmpdir/node-args" \
  || { echo 'playwright-mcp must launch the MCP with --isolated' >&2; exit 1; }

echo 'playwright-mcp smoke checks passed'

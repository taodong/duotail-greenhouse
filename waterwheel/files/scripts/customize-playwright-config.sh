#!/usr/bin/env bash
# Location: /usr/local/bin/customize-playwright-config
# Description: Customizes the Playwright MCP configuration at $AGENT_PATH/instructions/playwright-mcp-config.json.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
CONFIG_HELPERS_PATH="${CONFIG_HELPERS_PATH:-/config-helpers}"
CLEAR=false
TREAT_AS_SECURE=""

# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _name in agent-file-perms-lib; do
  _path="${_LIB}/${_name}"
  [ -f "${_path}.sh" ] && _path="${_path}.sh"
  # shellcheck disable=SC1090
  source "${_path}"
done

usage() {
  cat <<EOF
Usage: $(basename "$0") [-ap <agent-path>] [-cp <config-helpers-path>] <operation> [args] [help|h|--help|-h]

Customizes \$AGENT_PATH/instructions/playwright-mcp-config.json using
\$CONFIG_HELPERS_PATH/playwright-mcp-config-default.json as the base template.
All operations are replace-only: each run overwrites the output file
from the template (previous customizations are not accumulated).

Options:
  -ap, --agent-path <path>          Override agent path (default: /agent)
  -cp, --config-helpers-path <path> Override config-helpers path (default: /config-helpers)
  -h, --help, h, help               Show this help message

Operations:
  --clear
      Remove \$AGENT_PATH/instructions/playwright-mcp-config.json if it
      exists; do nothing otherwise. Cannot be combined with other operations.

  --treat-as-secure <domain1,domain2,...>
      Grant secure-context browser APIs to the given HTTP origins.
      Adds --unsafely-treat-insecure-origin-as-secure=<domains> and
      --ignore-certificate-errors to the Chromium launch args.
      Domains are comma-delimited HTTP URLs.

Examples:
  $(basename "$0") --clear
  $(basename "$0") -ap /tmp/my-agent --clear
  $(basename "$0") --treat-as-secure http://host.docker.internal:8080,http://host.docker.internal:8081
  $(basename "$0") -ap /tmp/my-agent --treat-as-secure http://host.docker.internal:8080
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap|--agent-path)
      AGENT_PATH="${2:?--agent-path requires a value}"
      shift 2
      ;;
    -cp|--config-helpers-path)
      CONFIG_HELPERS_PATH="${2:?--config-helpers-path requires a value}"
      shift 2
      ;;
    --clear)
      CLEAR=true
      shift
      ;;
    --treat-as-secure)
      TREAT_AS_SECURE="${2:?--treat-as-secure requires a value}"
      shift 2
      ;;
    -h|--help|h|help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$CLEAR" == false && -z "$TREAT_AS_SECURE" ]]; then
  echo "Error: no operation specified. Use --clear or --treat-as-secure." >&2
  usage >&2
  exit 1
fi

if [[ "$CLEAR" == true && -n "$TREAT_AS_SECURE" ]]; then
  echo "Error: --clear cannot be combined with other operations." >&2
  usage >&2
  exit 1
fi

TARGET_DIR="${AGENT_PATH}/instructions"
TARGET_FILE="${TARGET_DIR}/playwright-mcp-config.json"

if [[ "$CLEAR" == true ]]; then
  if [[ -f "$TARGET_FILE" ]]; then
    rm -f "$TARGET_FILE"
    echo "Removed ${TARGET_FILE}."
  else
    echo "No playwright-mcp-config.json found at ${TARGET_FILE}; nothing to do."
  fi
  exit 0
fi

# --treat-as-secure
TEMPLATE="${CONFIG_HELPERS_PATH}/playwright-mcp-config-default.json"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Error: template not found: ${TEMPLATE}" >&2
  exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: instructions directory not found: ${TARGET_DIR}" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"
jq --arg domains "$TREAT_AS_SECURE" '
  .browser.launchOptions.args |= (
    map(select(
      (startswith("--unsafely-treat-insecure-origin-as-secure") | not) and
      (. != "--ignore-certificate-errors")
    )) +
    ["--unsafely-treat-insecure-origin-as-secure=\($domains)", "--ignore-certificate-errors"]
  )
' "$TEMPLATE" > "$TMP_FILE"
mv "$TMP_FILE" "$TARGET_FILE"
enforce_managed_file_perms "$TARGET_FILE"

echo "Wrote ${TARGET_FILE} with --treat-as-secure for: ${TREAT_AS_SECURE}"

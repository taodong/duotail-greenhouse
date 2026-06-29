#!/usr/bin/env bash
# Location: /usr/local/bin/set-domain-permission
# Description: Generates the Playwright MCP allowed-domains.yaml from a comma-delimited list of domains.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
REWRITE_LOCALHOST=false
DOMAIN_ARGS=()

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
Usage: $(basename "$0") [-ap <agent-path>] [-l] <domain1,domain2,...> [help|h|--help|-h]

Generates \$AGENT_PATH/instructions/allowed-domains.yaml from a comma-delimited
list of domains. Each domain becomes one entry under the 'allowed' array.

Options:
  -ap, --agent-path <path>   Override agent path (default: /agent)
  -l                         Rewrite every 'localhost' in the domains to
                             'host.docker.internal' (useful inside Docker)
  -h, --help, h, help        Show this help message

Notes:
  - Domains are separated by commas. Quote entries that contain shell-special
    characters, e.g. "https://*.wikipedia.org".
  - Leading and trailing whitespace around each entry is trimmed.
  - Empty entries are ignored.

Examples:
  $(basename "$0") https://www.google.com,"https://*.wikipedia.org","http://localhost:8080"
  $(basename "$0") -l https://www.google.com,"http://localhost:8080"
  $(basename "$0") -ap /tmp/my-agent -l "http://localhost:8025"
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap|--agent-path)
      AGENT_PATH="${2:?--agent-path requires a value}"
      shift 2
      ;;
    -l)
      REWRITE_LOCALHOST=true
      shift
      ;;
    -h|--help|h|help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        DOMAIN_ARGS+=("$1")
        shift
      done
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      DOMAIN_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#DOMAIN_ARGS[@]} -eq 0 ]]; then
  echo "Error: no domains provided." >&2
  usage >&2
  exit 1
fi

# Join any space-separated positional arguments with commas so they are parsed
# the same way as a single comma-delimited argument.
RAW_DOMAINS="$(IFS=,; echo "${DOMAIN_ARGS[*]}")"

TARGET_DIR="${AGENT_PATH}/instructions"
TARGET_FILE="${TARGET_DIR}/allowed-domains.yaml"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: instructions directory not found: $TARGET_DIR" >&2
  exit 1
fi

# Split on commas, trim whitespace, drop empties, and rewrite localhost if asked.
ENTRIES=()
IFS=',' read -r -a _PARTS <<< "$RAW_DOMAINS"
for part in "${_PARTS[@]}"; do
  # Trim leading and trailing whitespace.
  part="${part#"${part%%[![:space:]]*}"}"
  part="${part%"${part##*[![:space:]]}"}"
  [[ -z "$part" ]] && continue
  if [[ "$REWRITE_LOCALHOST" == true ]]; then
    part="${part//localhost/host.docker.internal}"
  fi
  ENTRIES+=("$part")
done

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
  echo "Error: no valid domains after trimming empty entries." >&2
  exit 1
fi

TMP_FILE="$(mktemp)"
{
  echo "allowed:"
  for entry in "${ENTRIES[@]}"; do
    echo "  - ${entry}"
  done
} > "$TMP_FILE"
mv "$TMP_FILE" "$TARGET_FILE"
enforce_managed_file_perms "$TARGET_FILE"

echo "Wrote ${#ENTRIES[@]} domain(s) to ${TARGET_FILE}:"
for entry in "${ENTRIES[@]}"; do
  echo "  - ${entry}"
done

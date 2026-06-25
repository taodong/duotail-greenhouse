#!/usr/bin/env bash
# Location: /usr/local/bin/upload-instruction-file
# Description: Creates or replaces a file under $AGENT_PATH/instructions using stdin content.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
FILENAME=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [-ap <agent-path>] <filename>

Reads content from stdin and writes it to \$AGENT_PATH/instructions/<filename>,
creating the file or replacing it if it already exists.

Options:
  -ap, --agent-path <path>   Override agent path (default: /agent)
  -h, --help, h, help        Show this help message

Notes:
  - <filename> is appended to \$AGENT_PATH/instructions to form the full path.
  - Missing parent directories are created automatically.
  - A warning is printed when replacing an existing file.

Examples:
  printf 'allowed:\n  - http://host.docker.internal:8080\n' | \\
    $(basename "$0") allowed-domains.yaml
  cat ./extra-instructions.md | $(basename "$0") -ap /tmp/my-agent extra-instructions.md
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap|--agent-path)
      AGENT_PATH="${2:?--agent-path requires a value}"
      shift 2
      ;;
    -h|--help|h|help)
      usage
      exit 0
      ;;
    --)
      shift
      [[ $# -gt 0 ]] && { FILENAME="$1"; shift; }
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$FILENAME" ]]; then
        echo "Error: unexpected extra argument: $1" >&2
        usage >&2
        exit 1
      fi
      FILENAME="$1"
      shift
      ;;
  esac
done

if [[ -z "$FILENAME" ]]; then
  echo "Error: <filename> is required." >&2
  usage >&2
  exit 1
fi

TARGET_FILE="${AGENT_PATH}/instructions/${FILENAME}"

# Resolve file-upload-lib: prefer same directory (local dev), fall back to PATH (container).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${_SCRIPT_DIR}/file-upload-lib"
# shellcheck disable=SC1090
source "${_LIB}.sh" 2>/dev/null || source "${_LIB}"

cmd_upload "$TARGET_FILE"

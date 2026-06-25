#!/usr/bin/env bash
# Location: /usr/local/bin/upload-test-task
# Description: Creates or replaces a Markdown test task under $AGENT_PATH/tasks using stdin content.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
FILENAME=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [-ap <agent-path>] <filename.md>

Reads content from stdin and writes it to \$AGENT_PATH/tasks/<filename.md>,
creating the file or replacing it if it already exists. Only Markdown files
(filenames ending in ".md") are accepted.

Options:
  -ap, --agent-path <path>   Override agent path (default: /agent)
  -h, --help, h, help        Show this help message

Notes:
  - <filename.md> is appended to \$AGENT_PATH/tasks to form the full path.
  - The filename must end with ".md".
  - Missing parent directories are created automatically.
  - A warning is printed when replacing an existing file.

Examples:
  printf '# Login test\n' | $(basename "$0") login.md
  cat ./checkout.md | $(basename "$0") -ap /tmp/my-agent checkout.md
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
  echo "Error: <filename.md> is required." >&2
  usage >&2
  exit 1
fi

if [[ "$FILENAME" != *.md ]]; then
  echo "Error: filename must end with '.md': $FILENAME" >&2
  exit 1
fi

TARGET_FILE="${AGENT_PATH}/tasks/${FILENAME}"

# Resolve file-upload-lib: prefer same directory (local dev), fall back to PATH (container).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${_SCRIPT_DIR}/file-upload-lib"
# shellcheck disable=SC1090
source "${_LIB}.sh" 2>/dev/null || source "${_LIB}"

cmd_upload "$TARGET_FILE"

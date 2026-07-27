#!/usr/bin/env bash
# Location: /usr/local/bin/delete-builtin-skills
# Description: Deletes built-in skill folders under $AGENT_PATH/builtin-skills
#              matching a comma-delimited list of skill names. Exact matches only.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
SKILL_NAMES=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [-ap <agent-path>] -n <name1,name2,...>

Deletes built-in skill folders under <agent-path>/builtin-skills matching a
comma-delimited list of skill names. Only exact name matches are removed.

Options:
  -n, --names <names>        Comma-delimited built-in skill folder names to delete
  -ap, --agent-path <path>   Override agent path (default: /agent)
  -h, --help, h, help        Show this help message

Notes:
  - A leading "ww:" prefix on a name is ignored, so "ww:foo" targets "foo".
  - Names that do not match an existing folder are reported and skipped.
  - Path separators and traversal (e.g. ".", "..", "a/b") are rejected.

Examples:
  $(basename "$0") -n login-flow
  $(basename "$0") -n login-flow,checkout-flow
  $(basename "$0") -n ww:login-flow
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap|--agent-path)
      AGENT_PATH="${2:?--agent-path requires a value}"
      shift 2
      ;;
    -n|--names)
      SKILL_NAMES="${2:?--names requires a value}"
      shift 2
      ;;
    -h|--help|h|help)
      usage
      exit 0
      ;;
    --)
      shift
      if [[ $# -gt 0 ]]; then
        if [[ -n "$SKILL_NAMES" ]]; then
          echo "Error: unexpected extra argument: $1" >&2
          usage >&2
          exit 1
        fi
        SKILL_NAMES="$1"
        shift
      fi
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$SKILL_NAMES" ]]; then
        echo "Error: unexpected extra argument: $1" >&2
        usage >&2
        exit 1
      fi
      SKILL_NAMES="$1"
      shift
      ;;
  esac
done

if [[ -z "$SKILL_NAMES" ]]; then
  echo "Error: -n <name1,name2,...> is required." >&2
  usage >&2
  exit 1
fi

# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_path="${_LIB}/skill-delete-lib"
[ -f "${_path}.sh" ] && _path="${_path}.sh"
# shellcheck disable=SC1090
source "${_path}"

SKILLS_ROOT="${AGENT_PATH}/builtin-skills"

# Built-in skill names may carry a leading "ww:" prefix (stripped before matching).
parse_skill_names "$SKILL_NAMES" true
delete_skill_folders "$SKILLS_ROOT" "${PARSED_SKILL_NAMES[@]+"${PARSED_SKILL_NAMES[@]}"}"

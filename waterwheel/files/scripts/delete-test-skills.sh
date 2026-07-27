#!/usr/bin/env bash
# Location: /usr/local/bin/delete-test-skills
# Description: Deletes skill folders under $AGENT_PATH/skills (or $SKILLS_DIR)
#              matching a comma-delimited list of skill names.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
SKILLS_DIR="${SKILLS_DIR:-}"
SKILL_NAMES=""
DELETE_ALL=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [-ap <agent-path>] -n <name1,name2,...>
       $(basename "$0") [-ap <agent-path>] -a

Deletes skill folders under <skills-dir>, where <skills-dir> is \$SKILLS_DIR when
set, otherwise \$AGENT_PATH/skills. Either delete a comma-delimited list of skill
names (-n) or clear every user-defined skill (-a).

Options:
  -n, --names <names>        Comma-delimited skill folder names to delete
  -a, --all                  Delete all user-defined skills under <skills-dir>
                             (mutually exclusive with -n)
  -ap, --agent-path <path>   Override agent path (default: /agent)
  -h, --help, h, help        Show this help message

Notes:
  - Exactly one of -n or -a is required.
  - Only user-installed skills under <skills-dir> are removed; built-in skills
    are never touched.
  - \$SKILLS_DIR overrides the default \$AGENT_PATH/skills location.
  - Names that do not match an existing folder are reported and skipped.
  - Path separators and traversal (e.g. ".", "..", "a/b") are rejected.

Examples:
  $(basename "$0") -n login-flow
  $(basename "$0") -n login-flow,checkout-flow
  $(basename "$0") -a
  SKILLS_DIR=/tmp/skills $(basename "$0") -n login-flow
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
    -a|--all)
      DELETE_ALL=true
      shift
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

if [[ "$DELETE_ALL" == true && -n "$SKILL_NAMES" ]]; then
  echo "Error: -a/--all cannot be combined with skill names (-n or positional arguments)." >&2
  usage >&2
  exit 1
fi

if [[ "$DELETE_ALL" != true && -z "$SKILL_NAMES" ]]; then
  echo "Error: one of -n <name1,name2,...> or -a is required." >&2
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

SKILLS_ROOT="${SKILLS_DIR:-${AGENT_PATH}/skills}"
BUILTIN_ROOT="${AGENT_PATH}/builtin-skills"
if [[ "$SKILLS_ROOT" == "$BUILTIN_ROOT" || "$SKILLS_ROOT" == "$BUILTIN_ROOT/"* ]]; then
  echo "Error: refusing to operate on built-in skills directory: $SKILLS_ROOT" >&2
  exit 1
fi

PARSED_SKILL_NAMES=()
if [[ "$DELETE_ALL" == true ]]; then
  # Collect every user-defined skill folder directly under <skills-dir>.
  if [[ -d "$SKILLS_ROOT" ]]; then
    for folder in "$SKILLS_ROOT"/*/; do
      [[ -d "$folder" ]] || continue
      PARSED_SKILL_NAMES+=("$(basename "$folder")")
    done
  fi
else
  parse_skill_names "$SKILL_NAMES"
fi

delete_skill_folders "$SKILLS_ROOT" "${PARSED_SKILL_NAMES[@]+"${PARSED_SKILL_NAMES[@]}"}"

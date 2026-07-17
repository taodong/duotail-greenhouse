#!/usr/bin/env bash
# Location: /usr/local/bin/load-test-skills
# Description: Creates a skill folder under $AGENT_PATH/skills (or $SKILL_DIR)
#              named <skill-name> and writes stdin content to its SKILL.md.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
SKILL_DIR="${SKILL_DIR:-}"
SKILL_NAME=""
FORCE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [-ap <agent-path>] -name <skill-name> [--force]

Reads content from stdin and writes it to <skills-dir>/<skill-name>/SKILL.md,
where <skills-dir> is \$SKILL_DIR when set, otherwise \$AGENT_PATH/skills.

For an existing skill folder the write is skipped unless --force is given.

Options:
  -name, --name <skill-name> Name of the skill folder to create (required)
  -ap, --agent-path <path>   Override agent path (default: /agent)
  -f, --force                Overwrite an existing skill folder's SKILL.md
  -h, --help, h, help        Show this help message

Notes:
  - The skill folder is <skills-dir>/<skill-name>; SKILL.md is written inside it.
  - \$SKILL_DIR overrides the default \$AGENT_PATH/skills location.
  - Missing parent directories are created automatically.
  - An existing skill folder is skipped unless --force is provided.

Examples:
  cat ./SKILL.md | $(basename "$0") -name login-flow
  cat ./SKILL.md | $(basename "$0") -name login-flow --force
  cat ./SKILL.md | SKILL_DIR=/tmp/skills $(basename "$0") -name login-flow
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap|--agent-path)
      AGENT_PATH="${2:?--agent-path requires a value}"
      shift 2
      ;;
    -name|--name)
      SKILL_NAME="${2:?--name requires a value}"
      shift 2
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -h|--help|h|help)
      usage
      exit 0
      ;;
    --)
      shift
      [[ $# -gt 0 ]] && { SKILL_NAME="$1"; shift; }
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$SKILL_NAME" ]]; then
        echo "Error: unexpected extra argument: $1" >&2
        usage >&2
        exit 1
      fi
      SKILL_NAME="$1"
      shift
      ;;
  esac
done

if [[ -z "$SKILL_NAME" ]]; then
  echo "Error: -name <skill-name> is required." >&2
  usage >&2
  exit 1
fi

# Reject path separators and traversal so the skill name stays a single folder.
if [[ "$SKILL_NAME" == */* || "$SKILL_NAME" == "." || "$SKILL_NAME" == ".." ]]; then
  echo "Error: invalid skill name (no path separators allowed): $SKILL_NAME" >&2
  exit 1
fi

SKILLS_ROOT="${SKILL_DIR:-${AGENT_PATH}/skills}"
SKILL_FOLDER="${SKILLS_ROOT}/${SKILL_NAME}"
TARGET_FILE="${SKILL_FOLDER}/SKILL.md"

if [[ -d "$SKILL_FOLDER" && "$FORCE" != true ]]; then
  echo "Skipping existing skill folder: $SKILL_FOLDER (use --force to overwrite)" >&2
  # Drain stdin so upstream writers don't get a broken pipe.
  cat > /dev/null || true
  exit 0
fi

# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _name in file-upload-lib agent-file-perms-lib; do
  _path="${_LIB}/${_name}"
  [ -f "${_path}.sh" ] && _path="${_path}.sh"
  # shellcheck disable=SC1090
  source "${_path}"
done

cmd_upload "$TARGET_FILE"

# Make the new skill folder and its SKILL.md readable by agentuser via the
# agentgroup group bit, matching the managed skills/ directory model.
enforce_managed_dir_perms "$SKILL_FOLDER"
enforce_managed_file_perms "$TARGET_FILE"

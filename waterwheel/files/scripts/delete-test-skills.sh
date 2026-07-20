#!/usr/bin/env bash
# Location: /usr/local/bin/delete-test-skills
# Description: Deletes skill folders under $AGENT_PATH/skills (or $SKILL_DIR)
#              matching a comma-delimited list of skill names.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
SKILL_DIR="${SKILL_DIR:-}"
SKILL_NAMES=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [-ap <agent-path>] -names <name1,name2,...>

Deletes each matching skill folder under <skills-dir>, where <skills-dir> is
\$SKILL_DIR when set, otherwise \$AGENT_PATH/skills. Skill names are supplied as
a comma-delimited list.

Options:
  -names, --names <names>    Comma-delimited skill folder names to delete (required)
  -ap, --agent-path <path>   Override agent path (default: /agent)
  -h, --help, h, help        Show this help message

Notes:
  - Only user-installed skills under <skills-dir> are removed; built-in skills
    are never touched.
  - \$SKILL_DIR overrides the default \$AGENT_PATH/skills location.
  - Names that do not match an existing folder are reported and skipped.
  - Path separators and traversal (e.g. ".", "..", "a/b") are rejected.

Examples:
  $(basename "$0") -names login-flow
  $(basename "$0") -names login-flow,checkout-flow
  SKILL_DIR=/tmp/skills $(basename "$0") -names login-flow
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap|--agent-path)
      AGENT_PATH="${2:?--agent-path requires a value}"
      shift 2
      ;;
    -names|--names)
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
  echo "Error: -names <name1,name2,...> is required." >&2
  usage >&2
  exit 1
fi

SKILLS_ROOT="${SKILL_DIR:-${AGENT_PATH}/skills}"

deleted=0
skipped=0

# Split the comma-delimited list and process each name.
IFS=',' read -r -a _names <<< "$SKILL_NAMES"
for raw in "${_names[@]}"; do
  # Trim surrounding whitespace so "a, b" works as expected.
  name="${raw#"${raw%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"

  [[ -z "$name" ]] && continue

  # Reject path separators and traversal so the name stays a single folder.
  if [[ "$name" == */* || "$name" == "." || "$name" == ".." ]]; then
    echo "Error: invalid skill name (no path separators allowed): $name" >&2
    exit 1
  fi

  folder="${SKILLS_ROOT}/${name}"
  if [[ -d "$folder" ]]; then
    rm -rf "$folder"
    echo "Deleted skill: $name"
    deleted=$((deleted + 1))
  else
    echo "No matching skill folder: $name" >&2
    skipped=$((skipped + 1))
  fi
done

echo "Done. Deleted ${deleted} skill(s), skipped ${skipped}."

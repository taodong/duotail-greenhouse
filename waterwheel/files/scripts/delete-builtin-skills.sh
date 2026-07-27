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

SKILLS_ROOT="${AGENT_PATH}/builtin-skills"
deleted=0
skipped=0

names=()
# Split the comma-delimited list, trim/validate all names first (fail fast with no partial deletes).
IFS=',' read -r -a _raw_names <<< "$SKILL_NAMES"

for raw in "${_raw_names[@]}"; do
  # Trim surrounding whitespace so "a, b" works as expected.
  name="${raw#"${raw%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"

  # Drop a leading "ww:" prefix, then re-trim so "ww: foo" also works.
  name="${name#ww:}"
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"

  [[ -z "$name" ]] && continue

  # Reject path separators and traversal so the name stays a single folder.
  if [[ "$name" == */* || "$name" == "." || "$name" == ".." ]]; then
    echo "Error: invalid skill name (no path separators allowed): $name" >&2
    exit 1
  fi

  names+=("$name")
done

for name in "${names[@]+"${names[@]}"}"; do
  folder="${SKILLS_ROOT}/${name}"
  if [[ -d "$folder" ]]; then
    rm -rf -- "$folder"
    echo "Deleted skill: $name"
    deleted=$((deleted + 1))
  else
    echo "No matching skill folder: $name" >&2
    skipped=$((skipped + 1))
  fi
done

echo "Done. Deleted ${deleted} skill(s), skipped ${skipped}."

#!/usr/bin/env bash
# Location: /usr/local/bin/display-test-skills
# Description: Lists skills installed under $AGENT_PATH/builtin-skills and the
#              user skills dir ($SKILLS_DIR or $AGENT_PATH/skills), or prints a
#              single skill's SKILL.md.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
SHOW_SKILL=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [-ap <agent-path>] [--show|-s <skill-name>]

Without --show, lists every skill installed under \$AGENT_PATH/builtin-skills
and the user skills dir (\$SKILLS_DIR when set, otherwise \$AGENT_PATH/skills).
Built-in skills are marked as such.

With --show <skill-name>, prints the content of that skill's SKILL.md if the
skill exists in either location. Otherwise prints "No skill is matched.".

Options:
  -s, --show <skill-name>    Print the named skill's SKILL.md
  -ap, --agent-path <path>   Override agent path (default: /agent)
  -h, --help, h, help        Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") --show login-flow
  $(basename "$0") -ap /agent -s login-flow
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap|--agent-path)
      AGENT_PATH="${2:?--agent-path requires a value}"
      shift 2
      ;;
    -s|--show)
      SHOW_SKILL="${2:?--show requires a skill name}"
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
      echo "Error: unexpected argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

BUILTIN_DIR="${AGENT_PATH}/builtin-skills"
SKILLS_DIR="${SKILLS_DIR:-${AGENT_PATH}/skills}"

# --- Show mode: print a single skill's SKILL.md ------------------------------
if [[ -n "$SHOW_SKILL" ]]; then
  # Reject path separators and traversal so the name stays a single folder.
  if [[ "$SHOW_SKILL" == */* || "$SHOW_SKILL" == "." || "$SHOW_SKILL" == ".." ]]; then
    echo "Error: invalid skill name (no path separators allowed): $SHOW_SKILL" >&2
    exit 1
  fi

  # Prefer a user skill over a built-in one when both exist.
  for dir in "$SKILLS_DIR" "$BUILTIN_DIR"; do
    candidate="${dir}/${SHOW_SKILL}/SKILL.md"
    if [[ -f "$candidate" ]]; then
      cat "$candidate"
      exit 0
    fi
  done

  echo "No skill is matched."
  exit 0
fi

# --- List mode: enumerate all installed skills -------------------------------
found=false

list_skills() {
  local dir="$1"
  local label="$2"

  [[ -d "$dir" ]] || return 0

  local skill_path name
  for skill_path in "$dir"/*/; do
    [[ -d "$skill_path" ]] || continue
    name="$(basename "$skill_path")"
    if [[ -n "$label" ]]; then
      printf '%s %s\n' "$name" "$label"
    else
      printf '%s\n' "$name"
    fi
    found=true
  done
}

list_skills "$BUILTIN_DIR" "(built-in)"
list_skills "$SKILLS_DIR" ""

if [[ "$found" != true ]]; then
  echo "No skills installed."
fi

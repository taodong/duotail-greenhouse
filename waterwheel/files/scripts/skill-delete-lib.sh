#!/usr/bin/env bash
# Location: /usr/local/bin/skill-delete-lib
# Description: Shared helpers for delete-test-skills and delete-builtin-skills:
#              parsing/validating a comma-delimited name list and deleting the
#              matching skill folders under a given root.

# Trim surrounding whitespace from $1 and echo the result (no trailing newline).
_trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Parse a comma-delimited skill-name string into the PARSED_SKILL_NAMES array.
#   parse_skill_names <names-string> [strip_ww_prefix]
# Each name is whitespace-trimmed; when strip_ww_prefix is "true" a leading
# "ww:" prefix is dropped and the name re-trimmed. Names with path separators or
# traversal (".", "..", "a/b") are rejected. All names are validated up front,
# so an invalid name exits 1 before any deletion happens (no partial work).
parse_skill_names() {
  local names_string="$1" strip_ww_prefix="${2:-false}" raw name
  local _raw_names=()
  PARSED_SKILL_NAMES=()

  IFS=',' read -r -a _raw_names <<< "$names_string"
  for raw in "${_raw_names[@]}"; do
    name="$(_trim_ws "$raw")"
    if [[ "$strip_ww_prefix" == true ]]; then
      # Drop a leading "ww:" prefix, then re-trim so "ww: foo" also works.
      name="$(_trim_ws "${name#ww:}")"
    fi

    [[ -z "$name" ]] && continue

    # Reject path separators and traversal so the name stays a single folder.
    if [[ "$name" == */* || "$name" == "." || "$name" == ".." ]]; then
      echo "Error: invalid skill name (no path separators allowed): $name" >&2
      exit 1
    fi

    PARSED_SKILL_NAMES+=("$name")
  done
}

# Delete each named folder under <root>, then print a summary.
#   delete_skill_folders <root> <name>...
# Removes <root>/<name> recursively when it exists; a name with no matching
# folder is reported and skipped. Always exits after printing the summary line.
delete_skill_folders() {
  local root="$1"; shift
  local deleted=0 skipped=0 name folder

  for name in "$@"; do
    folder="${root}/${name}"
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
}

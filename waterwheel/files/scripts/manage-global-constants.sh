#!/usr/bin/env bash
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "-ap" ]]; then
    AGENT_PATH="$2"
    shift 2
fi

TARGET_FILE="${AGENT_PATH}/instructions/global-context.json"

# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
for _name in context-ops-lib agent-file-perms-lib; do
  _path="${_LIB}/${_name}"
  [ -f "${_path}.sh" ] && _path="${_path}.sh"
  # shellcheck disable=SC1090
  source "${_path}"
done

run_context_ops "manage-global-constants" "$TARGET_FILE" "$@"
enforce_managed_file_perms "$TARGET_FILE"

#!/usr/bin/env bash
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "-ap" ]]; then
    AGENT_PATH="$2"
    shift 2
fi

TARGET_FILE="${AGENT_PATH}/instructions/global-context.json"

# shellcheck source=context-ops-lib.sh
# Support both development (.sh) and container (no extension) installs.
_LIB="${SCRIPT_DIR}/context-ops-lib"
# shellcheck disable=SC1090
source "${_LIB}.sh" 2>/dev/null || source "${_LIB}"

run_context_ops "manage-global-constants" "$@"

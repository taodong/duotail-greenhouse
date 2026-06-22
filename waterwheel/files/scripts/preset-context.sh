#!/usr/bin/env bash
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "-ap" ]]; then
    if [ -z "${2:-}" ]; then
        echo "ERROR: -ap requires an agent path." >&2
        exit 1
    fi
    AGENT_PATH="$2"
    shift 2
fi

TARGET_FILE="${AGENT_PATH}/instructions/preset-context.json"

# shellcheck source=context-ops-lib.sh
# Support both development (.sh) and container (no extension) installs.
_LIB="${SCRIPT_DIR}/context-ops-lib"
# shellcheck disable=SC1090
source "${_LIB}.sh" 2>/dev/null || source "${_LIB}"

preset_context_usage() {
    cat <<EOF
Usage: preset-context [-ap <agent-path>] <family> [args]

Families:
   variables               Manage runtime values stored under .data
   flow                    List, import, or clear runtime flow definitions in .flow

Notes:
   - Variables and flow are mutually exclusive in a single call.
   - Flow import is file-path only and requires a JSON object containing {"flow":[...]}.
   - Use "preset-context flow list" to display existing flow entries.
   - Use "preset-context flow clear" to clear existing flow entries.
   - Mixed commands such as "preset-context flow ./flow.json variables set ..." are rejected.

Examples:
   preset-context variables list
   preset-context variables set username=admin,user.password=secret
   preset-context flow list
   preset-context flow ./instructions/flow.json
   preset-context flow clear
EOF
}

preset_context_variables_usage() {
    cat <<EOF
Usage: preset-context variables <operation> [args]

Operations:
   list                     Display current values in .data (or a message if none are set)
   set <pairs>              Set one or more key=value pairs in .data (comma-delimited)
   delete <keys>            Delete one or more keys from .data (comma-delimited)
   clear                    Clear .data; preserves .flow when present
   help | h                 Show this help message

Examples:
   preset-context variables list
   preset-context variables set BASE_URL="https://staging.example.com",TENANT=acme
   preset-context variables set user.username="qa_user",user.password="secret"
   preset-context variables delete BASE_URL,TENANT
   preset-context variables clear

Notes:
   - Key names are case-sensitive.
   - Values may be quoted or unquoted.
   - Dotted keys create nested objects beneath .data.
EOF
}

preset_context_list_flow() {
    if [ ! -f "$TARGET_FILE" ]; then
        echo "No flow is set."
        return 0
    fi

    local flow
    flow=$(jq '.flow // empty' "$TARGET_FILE")

    if [ -z "$flow" ]; then
        echo "No flow is set."
        return 0
    fi

    if jq -e '.flow | length == 0' "$TARGET_FILE" >/dev/null 2>&1; then
        echo "No flow is set."
        return 0
    fi

    jq '.flow' "$TARGET_FILE"
}

preset_context_import_flow() {
    local flow_file="$1"

    if [ ! -f "$flow_file" ]; then
        echo "ERROR: flow file '$flow_file' does not exist." >&2
        return 1
    fi

    local flow_json
    flow_json=$(jq -e '
        if type == "object" and has("flow") and (.flow | type == "array") then
            .flow
        else
            error("flow file must contain a top-level key named \"flow\" with an array value")
        end
    ' "$flow_file")

    local current_json="{}"
    if [ -f "$TARGET_FILE" ]; then
        current_json=$(cat "$TARGET_FILE")
    fi

    local result
    result=$(printf '%s' "$current_json" | jq --argjson flow "$flow_json" '{data: (.data // null), flow: $flow} | with_entries(select(.value != null))')

    local dir
    dir=$(dirname "$TARGET_FILE")
    mkdir -p "$dir"

    printf '%s\n' "$result" | jq . > "$TARGET_FILE"
    echo "Updated $TARGET_FILE"
}

preset_context_clear_flow() {
    if [ ! -f "$TARGET_FILE" ]; then
        echo "Nothing to clear — $TARGET_FILE does not exist."
        return 0
    fi

    local result
    result=$(jq 'if has("flow") then .flow = [] else . end' "$TARGET_FILE")

    if printf '%s' "$result" | jq -e '((.data // {}) | length == 0) and ((.flow // []) | length == 0)' >/dev/null 2>&1; then
        rm "$TARGET_FILE"
        echo "Cleared $TARGET_FILE"
        return 0
    fi

    printf '%s\n' "$result" | jq . > "$TARGET_FILE"
    echo "Cleared flow in $TARGET_FILE (data preserved)"
}

preset_context_variables() {
    local operation="${1:-}"

    case "$operation" in
        list|set|delete|clear)
            CONTEXT_PATH_PREFIX="data" \
            CONTEXT_LIST_QUERY='.data // {}' \
            CONTEXT_LIST_EMPTY_MESSAGE="No preset variables are set." \
            CONTEXT_CLEAR_DELETE_FILE_ONLY="false" \
            CONTEXT_CLEAR_SET_EXPR='if has("data") then .data = {} else . end' \
            CONTEXT_CLEAR_SUCCESS_MESSAGE="Cleared data in $TARGET_FILE (flow preserved)" \
            CONTEXT_EMPTY_CHECK_QUERY='((.data // {}) | length == 0) and ((.flow // []) | length == 0)' \
            run_context_ops "preset-context variables" "$TARGET_FILE" "$@"
            ;;
        help | h | --help | -h | "")
            preset_context_variables_usage
            ;;
        *)
            echo "ERROR: unknown variables operation '$operation'." >&2
            echo "" >&2
            preset_context_variables_usage >&2
            return 1
            ;;
    esac
}

case "${1:-}" in
    variables)
        shift
        preset_context_variables "$@"
        ;;
    flow)
        shift
        if [ $# -ne 1 ]; then
            echo "ERROR: flow accepts exactly one argument: list, <file-path>, or clear." >&2
            echo "" >&2
            preset_context_usage >&2
            exit 1
        fi
        if [ "$1" = "list" ]; then
            preset_context_list_flow
        elif [ "$1" = "clear" ]; then
            preset_context_clear_flow
        else
            preset_context_import_flow "$1"
        fi
        ;;
    help | h | --help | -h | "")
        preset_context_usage
        ;;
    *)
        echo "ERROR: unknown family '${1:-}'." >&2
        echo "" >&2
        preset_context_usage >&2
        exit 1
        ;;
esac





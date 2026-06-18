#!/usr/bin/env bash
# Shared library for managing JSON context files.
# Callers pass the target file path to run_context_ops.

context_ops_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

context_ops_build_path_json() {
    local key="$1"
    local -a path_parts=()
    local prefix="${CONTEXT_PATH_PREFIX:-}"
    local -a prefix_parts=()
    local -a key_parts=()
    local part

    if [ -n "$prefix" ]; then
        IFS='.' read -ra prefix_parts <<< "$prefix"
        for part in "${prefix_parts[@]}"; do
            [ -n "$part" ] && path_parts+=("$part")
        done
    fi

    if [ -n "$key" ]; then
        IFS='.' read -ra key_parts <<< "$key"
        for part in "${key_parts[@]}"; do
            [ -n "$part" ] && path_parts+=("$part")
        done
    fi

    if [ ${#path_parts[@]} -eq 0 ]; then
        printf '[]\n'
        return 0
    fi

    printf '%s\n' "${path_parts[@]}" | jq -R . | jq -s .
}

context_ops_prune_json() {
    local json="$1"
    local path_json="${2:-}"

    if [ -z "$path_json" ]; then
        printf '%s' "$json" | jq '
            def prune_empty:
                if type == "object" then
                    with_entries(.value |= prune_empty)
                    | with_entries(select(.value != {} and .value != [] and .value != null))
                elif type == "array" then
                    map(prune_empty)
                    | map(select(. != {} and . != [] and . != null))
                else . end;
            prune_empty
        '
    else
        printf '%s' "$json" | jq --argjson path "$path_json" '
            def prune_empty:
                if type == "object" then
                    with_entries(.value |= prune_empty)
                    | with_entries(select(.value != {} and .value != [] and .value != null))
                elif type == "array" then
                    map(prune_empty)
                    | map(select(. != {} and . != [] and . != null))
                else . end;
            setpath($path; ((getpath($path) // {}) | prune_empty))
        '
    fi
}

context_ops_is_empty_json() {
    local json="$1"
    local query="${CONTEXT_EMPTY_CHECK_QUERY:-length == 0}"
    printf '%s' "$json" | jq -e "$query" >/dev/null 2>&1
}

context_ops_compact_keys() {
    local -a keys=("$@")
    local output=""
    local key
    for key in "${keys[@]}"; do
        [[ -n "$output" ]] && output+=", "
        output+="$key"
    done
    printf '%s' "$output"
}

cmd_list() {
    local target_file="$1"
    local empty_message="${CONTEXT_LIST_EMPTY_MESSAGE:-No global values are set.}"
    local query="${CONTEXT_LIST_QUERY:-.}"

    if [ ! -f "$target_file" ]; then
        echo "$empty_message"
        return 0
    fi

    jq "$query" "$target_file"
}

cmd_set() {
    local target_file="$1"
    local pairs_string="$2"

    if [ -z "$pairs_string" ]; then
        echo "ERROR: set requires key=value pairs (e.g. KEY=val,OTHER=\"quoted val\")." >&2
        return 1
    fi

    # Parse comma-delimited pairs while respecting double-quoted regions.
    local -a pairs=()
    local current=""
    local in_quote=0
    local i

    for ((i = 0; i < ${#pairs_string}; i++)); do
        local char="${pairs_string:$i:1}"
        if [[ "$char" == '"' ]]; then
            in_quote=$((1 - in_quote))
            current+="$char"
        elif [[ "$char" == ',' && $in_quote -eq 0 ]]; then
            pairs+=("$current")
            current=""
        else
            current+="$char"
        fi
    done
    [[ -n "$current" ]] && pairs+=("$current")

    local json="{}"
    if [ -f "$target_file" ]; then
        json=$(cat "$target_file")
    fi

    local pair
    for pair in "${pairs[@]}"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"

        key=$(context_ops_trim "$key")

        if [ -z "$key" ]; then
            echo "WARNING: skipping empty key in pair: $pair" >&2
            continue
        fi

        if [[ "$value" == '"'*'"' ]]; then
            value="${value#\"}"
            value="${value%\"}"
        fi

        local path_json
        path_json=$(context_ops_build_path_json "$key")
        json=$(printf '%s' "$json" | jq --argjson path "$path_json" --arg v "$value" 'setpath($path; $v)')
    done

    local dir
    dir=$(dirname "$target_file")
    mkdir -p "$dir"

    printf '%s\n' "$json" | jq . > "$target_file"
    echo "Updated $target_file"
}

cmd_clear() {
    local target_file="$1"

    if [ ! -f "$target_file" ]; then
        echo "Nothing to clear — $target_file does not exist."
        return 0
    fi

    if [ "${CONTEXT_CLEAR_DELETE_FILE_ONLY:-true}" = "true" ]; then
        rm "$target_file"
        echo "Cleared $target_file"
        return 0
    fi

    local clear_expr="${CONTEXT_CLEAR_SET_EXPR:-.}"
    local result
    result=$(jq "$clear_expr" "$target_file")

    if context_ops_is_empty_json "$result"; then
        rm "$target_file"
        echo "Cleared $target_file"
        return 0
    fi

    printf '%s\n' "$result" | jq . > "$target_file"
    echo "${CONTEXT_CLEAR_SUCCESS_MESSAGE:-Cleared $target_file}"
}

cmd_delete() {
    local target_file="$1"
    local keys_string="$2"

    if [ -z "$keys_string" ]; then
        echo "ERROR: delete requires a comma-delimited list of key names." >&2
        return 1
    fi

    if [ ! -f "$target_file" ]; then
        echo "ERROR: $target_file does not exist." >&2
        return 1
    fi

    IFS=',' read -ra raw_keys <<< "$keys_string"

    local -a to_delete=()
    local -a not_found=()
    local raw_key

    for raw_key in "${raw_keys[@]}"; do
        local key
        key=$(context_ops_trim "$raw_key")
        [ -z "$key" ] && continue

        local path_json
        path_json=$(context_ops_build_path_json "$key")

        local exists
        exists=$(jq --argjson path "$path_json" 'getpath($path) != null' "$target_file" 2>/dev/null || echo "false")
        if [ "$exists" = "true" ]; then
            to_delete+=("$key")
        else
            not_found+=("$key")
        fi
    done

    if [ ${#not_found[@]} -gt 0 ]; then
        echo "WARNING: unknown keys: $(context_ops_compact_keys "${not_found[@]}")"
    fi

    if [ ${#to_delete[@]} -eq 0 ]; then
        return 0
    fi

    local result
    result=$(cat "$target_file")

    local key
    for key in "${to_delete[@]}"; do
        local path_json
        path_json=$(context_ops_build_path_json "$key")
        result=$(printf '%s' "$result" | jq --argjson path "$path_json" 'delpaths([$path])')
    done

    if [ -n "${CONTEXT_PATH_PREFIX:-}" ]; then
        local prefix_path_json
        prefix_path_json=$(context_ops_build_path_json "")
        result=$(context_ops_prune_json "$result" "$prefix_path_json")
    else
        result=$(context_ops_prune_json "$result")
    fi

    if context_ops_is_empty_json "$result"; then
        rm "$target_file"
        if [ -n "${CONTEXT_DELETE_EMPTY_MESSAGE:-}" ]; then
            echo "$CONTEXT_DELETE_EMPTY_MESSAGE"
        else
            echo "All keys removed. Deleted $target_file."
        fi
        return 0
    fi

    printf '%s\n' "$result" | jq . > "$target_file"
    echo "Deleted: $(context_ops_compact_keys "${to_delete[@]}")"
}

cmd_help() {
    local script_name="$1"
    cat <<EOF
Usage: $script_name <operation> [args]

Operations:
   list                     Display current values (or a message if none are set)
   set <pairs>              Set one or more key=value pairs (comma-delimited)
   delete <keys>            Delete one or more keys (comma-delimited)
   clear                    Clear the context file or managed subtree
   help | h                 Show this help message

Examples:
   $script_name list
   $script_name set BASE_URL="https://staging.example.com",TENANT=acme
   $script_name set user.username="qa_user",user.password="secret"
   $script_name delete BASE_URL,TENANT
   $script_name clear

Notes:
   - Key names are case-sensitive.
   - Values may be quoted or unquoted.
   - Dotted keys create nested objects (for example: user.username=abc -> {"user":{"username":"abc"}}).
EOF
}

run_context_ops() {
    local script_name="$1"
    local target_file="$2"
    shift 2

    if [ -z "$target_file" ]; then
        echo "ERROR: target file is required for run_context_ops." >&2
        return 1
    fi

    local operation="${1:-}"

    case "$operation" in
        list)
            if [ $# -ne 1 ]; then
                echo "ERROR: list does not accept additional arguments." >&2
                return 1
            fi
            cmd_list "$target_file"
            ;;
        set)
            if [ $# -ne 2 ]; then
                echo "ERROR: set requires exactly one comma-delimited key=value argument." >&2
                return 1
            fi
            cmd_set "$target_file" "${2:-}"
            ;;
        delete)
            if [ $# -ne 2 ]; then
                echo "ERROR: delete requires exactly one comma-delimited key list." >&2
                return 1
            fi
            cmd_delete "$target_file" "${2:-}"
            ;;
        clear)
            if [ $# -ne 1 ]; then
                echo "ERROR: clear does not accept additional arguments." >&2
                return 1
            fi
            cmd_clear "$target_file"
            ;;
        help | h | --help | -h)
            if [ $# -ne 1 ]; then
                echo "ERROR: help does not accept additional arguments." >&2
                return 1
            fi
            cmd_help "$script_name"
            ;;
        "")
            echo "ERROR: no operation specified." >&2
            echo "" >&2
            cmd_help "$script_name" >&2
            exit 1
            ;;
        *)
            echo "ERROR: unknown operation '$operation'." >&2
            echo "" >&2
            cmd_help "$script_name" >&2
            exit 1
            ;;
    esac
}

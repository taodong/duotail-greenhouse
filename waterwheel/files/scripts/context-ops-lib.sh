#!/usr/bin/env bash
# Shared library for managing JSON context files.
# Callers must set TARGET_FILE before sourcing this script.

cmd_list() {
    if [ ! -f "$TARGET_FILE" ]; then
        if is_preset_mode; then
            echo "No context values are set."
        else
            echo "No global values are set."
        fi
        return 0
    fi
    jq . "$TARGET_FILE"
}

# Context modes:
# - flat   (default): legacy root-level key/value JSON
# - preset: preset-context.json with {data, flow} shape
is_preset_mode() {
    [ "${CONTEXT_OPS_MODE:-flat}" = "preset" ]
}

is_preset_json_empty_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 0
    fi
    jq -e '((.data // {}) | length == 0) and ((.flow // []) | length == 0)' "$file" >/dev/null 2>&1
}

is_preset_json_empty_string() {
    local json="$1"
    printf '%s' "$json" | jq -e '((.data // {}) | length == 0) and ((.flow // []) | length == 0)' >/dev/null 2>&1
}

cmd_set() {
    local pairs_string="$1"

    if [ -z "$pairs_string" ]; then
        echo "ERROR: set requires key=value pairs (e.g. KEY=val,OTHER=\"quoted val\")." >&2
        return 1
    fi

    # Parse comma-delimited pairs while respecting double-quoted regions.
    local -a pairs=()
    local current=""
    local in_quote=0

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
    if [ -f "$TARGET_FILE" ]; then
        json=$(cat "$TARGET_FILE")
    fi

    if is_preset_mode; then
        # Ensure .data section exists for preset-context schema.
        json=$(printf '%s' "$json" | jq '.data //= {}')
    fi

    for pair in "${pairs[@]}"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"

        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        if [ -z "$key" ]; then
            echo "WARNING: skipping empty key in pair: $pair" >&2
            continue
        fi

        # Strip surrounding double quotes from value.
        if [[ "$value" == '"'*'"' ]]; then
            value="${value#\"}"
            value="${value%\"}"
        fi

        if is_preset_mode; then
            # Parse dotted notation and set nested values under .data.
            local -a path_parts=("data")
            local -a key_parts=()
            IFS='.' read -ra key_parts <<< "$key"
            local part
            for part in "${key_parts[@]}"; do
                path_parts+=("$part")
            done

            local path_json
            path_json=$(printf '%s\n' "${path_parts[@]}" | jq -R . | jq -s .)
            json=$(printf '%s' "$json" | jq --argjson path "$path_json" --arg v "$value" 'setpath($path; $v)')
        else
            # Legacy behavior for global-context.json and other flat files.
            json=$(printf '%s' "$json" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
        fi
    done

    local dir
    dir=$(dirname "$TARGET_FILE")
    mkdir -p "$dir"

    printf '%s\n' "$json" | jq . > "$TARGET_FILE"
    echo "Updated $TARGET_FILE"
}

cmd_clear() {
    if [ ! -f "$TARGET_FILE" ]; then
        echo "Nothing to clear — $TARGET_FILE does not exist."
        return 0
    fi

    if is_preset_mode; then
        # Clear only data; preserve flow and delete file only when both are empty.
        local result
        result=$(jq 'if has("data") then .data = {} else . end' "$TARGET_FILE")
        if is_preset_json_empty_string "$result"; then
            rm "$TARGET_FILE"
            echo "Cleared $TARGET_FILE"
        else
            printf '%s\n' "$result" | jq . > "$TARGET_FILE"
            echo "Cleared data in $TARGET_FILE (flow preserved)"
        fi
    else
        # Legacy behavior for flat files.
        rm "$TARGET_FILE"
        echo "Cleared $TARGET_FILE"
    fi
}

cmd_delete() {
    local keys_string="$1"

    if [ -z "$keys_string" ]; then
        echo "ERROR: delete requires a comma-delimited list of key names." >&2
        return 1
    fi

    if [ ! -f "$TARGET_FILE" ]; then
        echo "ERROR: $TARGET_FILE does not exist." >&2
        return 1
    fi

    IFS=',' read -ra raw_keys <<< "$keys_string"

    local -a to_delete=()
    local -a not_found=()

    for raw_key in "${raw_keys[@]}"; do
        local key="${raw_key#"${raw_key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [ -z "$key" ] && continue

        if is_preset_mode; then
            # Support dotted paths for nested keys under .data.
            local -a path_parts=("data")
            local -a key_parts=()
            IFS='.' read -ra key_parts <<< "$key"
            local part
            for part in "${key_parts[@]}"; do
                path_parts+=("$part")
            done
            local path_json
            path_json=$(printf '%s\n' "${path_parts[@]}" | jq -R . | jq -s .)

            local exists
            exists=$(jq --argjson path "$path_json" 'getpath($path) != null' "$TARGET_FILE" 2>/dev/null || echo "false")
            if [ "$exists" = "true" ]; then
                to_delete+=("$key")
            else
                not_found+=("$key")
            fi
        else
            local exists
            exists=$(jq --arg k "$key" 'has($k)' "$TARGET_FILE" 2>/dev/null || echo "false")
            if [ "$exists" = "true" ]; then
                to_delete+=("$key")
            else
                not_found+=("$key")
            fi
        fi
    done

    if [ ${#not_found[@]} -gt 0 ]; then
        local warn_str=""
        for k in "${not_found[@]}"; do
            [[ -n "$warn_str" ]] && warn_str+=", "
            warn_str+="$k"
        done
        echo "WARNING: unknown keys: $warn_str"
    fi

    if [ ${#to_delete[@]} -eq 0 ]; then
        return 0
    fi

    local result
    if is_preset_mode; then
        result=$(cat "$TARGET_FILE")
        local key
        for key in "${to_delete[@]}"; do
            local -a path_parts=("data")
            local -a key_parts=()
            IFS='.' read -ra key_parts <<< "$key"
            local part
            for part in "${key_parts[@]}"; do
                path_parts+=("$part")
            done
            local path_json
            path_json=$(printf '%s\n' "${path_parts[@]}" | jq -R . | jq -s .)
            result=$(printf '%s' "$result" | jq --argjson path "$path_json" 'delpaths([$path])')
        done

        # Remove empty nested objects left by dotted-path deletions.
        result=$(printf '%s' "$result" | jq '
            def prune_empty:
                if type == "object" then
                    with_entries(.value |= prune_empty)
                    | with_entries(select(.value != {} and .value != [] and .value != null))
                elif type == "array" then
                    map(prune_empty)
                    | map(select(. != {} and . != [] and . != null))
                else . end;
            .data = ((.data // {}) | prune_empty)
        ')

        if is_preset_json_empty_string "$result"; then
            rm "$TARGET_FILE"
            echo "All data keys removed. Deleted $TARGET_FILE."
            return 0
        fi

        printf '%s\n' "$result" | jq . > "$TARGET_FILE"
        local deleted_str=""
        for key in "${to_delete[@]}"; do
            [[ -n "$deleted_str" ]] && deleted_str+=", "
            deleted_str+="$key"
        done
        echo "Deleted from data: $deleted_str"
    else
        local jq_keys_json
        jq_keys_json=$(printf '%s\n' "${to_delete[@]}" | jq -R . | jq -s .)
        result=$(jq --argjson keys "$jq_keys_json" 'del(.[$keys[]])' "$TARGET_FILE")
        if [ "$result" = "{}" ]; then
            rm "$TARGET_FILE"
            echo "All keys removed. Deleted $TARGET_FILE."
            return 0
        fi

        printf '%s\n' "$result" | jq . > "$TARGET_FILE"
        local deleted_str=""
        local key
        for key in "${to_delete[@]}"; do
            [[ -n "$deleted_str" ]] && deleted_str+=", "
            deleted_str+="$key"
        done
        echo "Deleted: $deleted_str"
    fi
}

cmd_help() {
    local script_name="$1"
    if is_preset_mode; then
        cat <<EOF
Usage: $script_name <operation> [args]

Mode:
   preset                  Values are stored under "data" in preset-context.json

Operations:
   list                     Display current values (or a message if none are set)
   set <pairs>              Set one or more key=value pairs under data (comma-delimited)
   delete <keys>            Delete one or more keys from data (comma-delimited)
   clear                    Clear data values; preserves flow when present
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
   - Dotted keys (e.g., "user.username") are nested under "data".
EOF
    else
        cat <<EOF
Usage: $script_name <operation> [args]

Mode:
   flat                    Values are stored as root-level keys in JSON

Operations:
   list                     Display current values (or a message if none are set)
   set <pairs>              Set one or more key=value pairs (comma-delimited)
   delete <keys>            Delete one or more keys (comma-delimited)
   clear                    Delete the entire context file
   help | h                 Show this help message

Examples:
   $script_name list
   $script_name set BASE_URL="https://staging.example.com",TENANT=acme
   $script_name delete BASE_URL,TENANT
   $script_name clear

Notes:
   - Key names are case-sensitive.
   - Values may be quoted or unquoted.
EOF
    fi
}

run_context_ops() {
    local script_name="$1"
    shift
    local operation="${1:-}"

    case "$operation" in
        list)
            cmd_list
            ;;
        set)
            cmd_set "${2:-}"
            ;;
        delete)
            cmd_delete "${2:-}"
            ;;
        clear)
            cmd_clear
            ;;
        help | h | --help | -h)
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

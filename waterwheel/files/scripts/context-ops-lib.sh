#!/usr/bin/env bash
# Shared library for managing JSON context files.
# Callers must set TARGET_FILE before sourcing this script.

cmd_list() {
    if [ ! -f "$TARGET_FILE" ]; then
        echo "No global values are set."
        return 0
    fi
    jq . "$TARGET_FILE"
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

        json=$(printf '%s' "$json" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
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
    rm "$TARGET_FILE"
    echo "Cleared $TARGET_FILE"
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

        local exists
        exists=$(jq --arg k "$key" 'has($k)' "$TARGET_FILE")
        if [ "$exists" = "true" ]; then
            to_delete+=("$key")
        else
            not_found+=("$key")
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

    local jq_keys_json
    jq_keys_json=$(printf '%s\n' "${to_delete[@]}" | jq -R . | jq -s .)

    local result
    result=$(jq --argjson keys "$jq_keys_json" 'del(.[$keys[]])' "$TARGET_FILE")

    if [ "$result" = "{}" ]; then
        rm "$TARGET_FILE"
        echo "All keys removed. Deleted $TARGET_FILE."
    else
        printf '%s\n' "$result" | jq . > "$TARGET_FILE"
        local deleted_str=""
        for k in "${to_delete[@]}"; do
            [[ -n "$deleted_str" ]] && deleted_str+=", "
            deleted_str+="$k"
        done
        echo "Deleted: $deleted_str"
    fi
}

cmd_help() {
    local script_name="$1"
    cat <<EOF
Usage: $script_name <operation> [args]

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
  - Deleting all keys removes the file automatically.
EOF
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

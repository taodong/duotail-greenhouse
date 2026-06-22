#!/usr/bin/env bash
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
TASKS_DIR=""
TASK_MARKDOWN_FILES=()

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

usage() {
    cat <<EOF
Usage: manage-test-files [-ap <agent-path>] <operation> [args]

Operations:
   list                        List markdown test files under \$AGENT_PATH/tasks
   add <paths>                 Add local files/directories (comma-delimited)
   clear                       Delete all markdown test files under \$AGENT_PATH/tasks
   delete <selectors>          Delete by index or filename (comma-delimited)
   help | h                    Show this help message

Arguments:
   <paths>                     Comma-delimited file/directory paths
                               - File path: copy if it ends with .md
                               - Directory path: copy only direct child .md files
                               - Non-markdown files are ignored
                               - Existing destination basenames are overwritten (warned)

   <selectors>                 Comma-delimited selectors
                               - Numeric selector: 1-based index from 'list'
                               - String selector: exact markdown filename (basename only)
                               - Best effort: invalid selectors are warned and skipped

Examples:
   manage-test-files list
   manage-test-files add ./tests/a.md,./tests/b.md
   manage-test-files add ./tests/smoke,./tests/login.md
   manage-test-files delete 1,3
   manage-test-files delete login.md,2
   manage-test-files clear
EOF
}

collect_markdown_files() {
    TASK_MARKDOWN_FILES=()

    if [ ! -d "$TASKS_DIR" ]; then
        return 0
    fi

    while IFS= read -r file; do
        TASK_MARKDOWN_FILES+=("$file")
    done < <(
        find "$TASKS_DIR" -maxdepth 1 -mindepth 1 -type f -name "*.md" -print \
            | sed "s|^${TASKS_DIR}/||" \
            | LC_ALL=C sort
    )
}

list_test_files() {
    collect_markdown_files

    if [ ${#TASK_MARKDOWN_FILES[@]} -eq 0 ]; then
        echo "No markdown test files found in $TASKS_DIR."
        return 0
    fi

    local i=1
    local file
    for file in "${TASK_MARKDOWN_FILES[@]}"; do
        printf '%d. %s\n' "$i" "$file"
        i=$((i + 1))
    done
}

copy_markdown_file() {
    local src="$1"
    local dst_basename
    dst_basename="$(basename "$src")"

    local dst_path="$TASKS_DIR/$dst_basename"
    local overwritten=false
    if [ -f "$dst_path" ]; then
        overwritten=true
    fi

    cp -f "$src" "$dst_path"

    if [ "$overwritten" = true ]; then
        printf '%s' "$dst_basename"
    fi
}

add_test_files() {
    local paths_csv="$1"

    if [ -z "$paths_csv" ]; then
        echo "ERROR: add requires a comma-delimited list of paths." >&2
        return 1
    fi

    mkdir -p "$TASKS_DIR"

    local -a raw_paths=()
    IFS=',' read -ra raw_paths <<< "$paths_csv"

    local copied=0
    local ignored_non_md=0
    local missing=0
    local overwrite_warnings=0

    local -a overwrite_basenames=()
    local -a overwrite_counts=()

    local raw_path
    for raw_path in "${raw_paths[@]}"; do
        local path
        path="$(trim "$raw_path")"
        [ -z "$path" ] && continue

        if [ -f "$path" ]; then
            if [[ "$path" == *.md ]]; then
                local overwritten_basename=""
                overwritten_basename="$(copy_markdown_file "$path")"

                copied=$((copied + 1))

                if [ -n "$overwritten_basename" ]; then
                    local found=false
                    local idx
                    for idx in "${!overwrite_basenames[@]}"; do
                        if [ "${overwrite_basenames[$idx]}" = "$overwritten_basename" ]; then
                            overwrite_counts[$idx]=$((overwrite_counts[$idx] + 1))
                            found=true
                            break
                        fi
                    done
                    if [ "$found" = false ]; then
                        overwrite_basenames+=("$overwritten_basename")
                        overwrite_counts+=(1)
                    fi
                    overwrite_warnings=$((overwrite_warnings + 1))
                fi
            else
                ignored_non_md=$((ignored_non_md + 1))
            fi
            continue
        fi

        if [ -d "$path" ]; then
            local child
            while IFS= read -r -d '' child; do
                if [[ "$child" == *.md ]]; then
                    local overwritten_basename=""
                    overwritten_basename="$(copy_markdown_file "$child")"

                    copied=$((copied + 1))

                    if [ -n "$overwritten_basename" ]; then
                        local found=false
                        local idx
                        for idx in "${!overwrite_basenames[@]}"; do
                            if [ "${overwrite_basenames[$idx]}" = "$overwritten_basename" ]; then
                                overwrite_counts[$idx]=$((overwrite_counts[$idx] + 1))
                                found=true
                                break
                            fi
                        done
                        if [ "$found" = false ]; then
                            overwrite_basenames+=("$overwritten_basename")
                            overwrite_counts+=(1)
                        fi
                        overwrite_warnings=$((overwrite_warnings + 1))
                    fi
                else
                    ignored_non_md=$((ignored_non_md + 1))
                fi
            done < <(find "$path" -maxdepth 1 -mindepth 1 -type f -print0)
            continue
        fi

        echo "WARNING: path not found, skipped: $path" >&2
        missing=$((missing + 1))
    done

    if [ ${#overwrite_basenames[@]} -gt 0 ]; then
        while IFS=$'\t' read -r basename count; do
            [ -z "$basename" ] && continue
            echo "WARNING: destination basename overwritten: $basename ($count time(s))" >&2
        done < <(
            local idx
            for idx in "${!overwrite_basenames[@]}"; do
                printf '%s\t%s\n' "${overwrite_basenames[$idx]}" "${overwrite_counts[$idx]}"
            done | LC_ALL=C sort -t $'\t' -k1,1
        )
    fi

    echo "Added/updated $copied markdown file(s) into $TASKS_DIR."
    if [ "$ignored_non_md" -gt 0 ]; then
        echo "Ignored $ignored_non_md non-markdown file(s)."
    fi
    if [ "$missing" -gt 0 ]; then
        echo "Skipped $missing missing path(s)."
    fi

    local total_warnings=$((ignored_non_md + missing + overwrite_warnings))
    if [ "$total_warnings" -gt 0 ]; then
        echo "Completed with $total_warnings warning(s)."
    fi

    return 0
}

clear_test_files() {
    if [ ! -d "$TASKS_DIR" ]; then
        echo "No markdown test files found in $TASKS_DIR."
        return 0
    fi

    local deleted=0
    local file
    while IFS= read -r -d '' file; do
        rm -f "$file"
        deleted=$((deleted + 1))
    done < <(find "$TASKS_DIR" -maxdepth 1 -mindepth 1 -type f -name "*.md" -print0)

    echo "Cleared $deleted markdown test file(s) from $TASKS_DIR."
}

delete_test_files() {
    local selectors_csv="$1"

    if [ -z "$selectors_csv" ]; then
        echo "ERROR: delete requires a comma-delimited list of selectors." >&2
        return 1
    fi

    collect_markdown_files

    if [ ${#TASK_MARKDOWN_FILES[@]} -eq 0 ]; then
        echo "No markdown test files found in $TASKS_DIR."
        return 0
    fi

    local -a raw_selectors=()
    IFS=',' read -ra raw_selectors <<< "$selectors_csv"

    local -a targets=()
    local warnings=0

    local raw_selector
    for raw_selector in "${raw_selectors[@]}"; do
        local selector
        selector="$(trim "$raw_selector")"
        [ -z "$selector" ] && continue

        local target=""
        if [[ "$selector" =~ ^[0-9]+$ ]]; then
            local idx="$selector"
            if (( idx < 1 || idx > ${#TASK_MARKDOWN_FILES[@]} )); then
                echo "WARNING: index out of range, skipped: $selector" >&2
                warnings=$((warnings + 1))
                continue
            fi
            target="${TASK_MARKDOWN_FILES[$((idx-1))]}"
        else
            local matched=false
            local candidate
            for candidate in "${TASK_MARKDOWN_FILES[@]}"; do
                if [ "$candidate" = "$selector" ]; then
                    target="$candidate"
                    matched=true
                    break
                fi
            done
            if [ "$matched" = false ]; then
                echo "WARNING: filename not found, skipped: $selector" >&2
                warnings=$((warnings + 1))
                continue
            fi
        fi

        local seen=false
        local picked
        if [ ${#targets[@]} -gt 0 ]; then
            for picked in "${targets[@]}"; do
                if [ "$picked" = "$target" ]; then
                    seen=true
                    break
                fi
            done
        fi
        if [ "$seen" = false ]; then
            targets+=("$target")
        fi
    done

    local deleted=0
    local target
    for target in "${targets[@]}"; do
        local full_path="$TASKS_DIR/$target"
        if [ -f "$full_path" ]; then
            rm -f "$full_path"
            deleted=$((deleted + 1))
        else
            echo "WARNING: file no longer exists, skipped: $target" >&2
            warnings=$((warnings + 1))
        fi
    done

    echo "Deleted $deleted markdown file(s) from $TASKS_DIR."
    if [ "$warnings" -gt 0 ]; then
        echo "Completed with $warnings warning(s)."
    fi

    return 0
}

if [[ "${1:-}" == "-ap" ]]; then
    if [ -z "${2:-}" ]; then
        echo "ERROR: -ap requires an agent path." >&2
        exit 1
    fi
    AGENT_PATH="$2"
    shift 2
fi

TASKS_DIR="${AGENT_PATH}/tasks"

operation="${1:-}"
case "$operation" in
    list)
        if [ $# -ne 1 ]; then
            echo "ERROR: list does not accept additional arguments." >&2
            exit 1
        fi
        list_test_files
        ;;
    add)
        if [ $# -ne 2 ]; then
            echo "ERROR: add requires exactly one comma-delimited path argument." >&2
            exit 1
        fi
        add_test_files "$2"
        ;;
    clear)
        if [ $# -ne 1 ]; then
            echo "ERROR: clear does not accept additional arguments." >&2
            exit 1
        fi
        clear_test_files
        ;;
    delete)
        if [ $# -ne 2 ]; then
            echo "ERROR: delete requires exactly one comma-delimited selector argument." >&2
            exit 1
        fi
        delete_test_files "$2"
        ;;
    help | h | --help | -h)
        if [ $# -ne 1 ]; then
            echo "ERROR: help does not accept additional arguments." >&2
            exit 1
        fi
        usage
        ;;
    "")
        echo "ERROR: no operation specified." >&2
        echo "" >&2
        usage >&2
        exit 1
        ;;
    *)
        echo "ERROR: unknown operation '$operation'." >&2
        echo "" >&2
        usage >&2
        exit 1
        ;;
esac





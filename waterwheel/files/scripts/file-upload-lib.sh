#!/usr/bin/env bash
# Shared library for saving stdin content to a target file path.
# Can be sourced by other scripts or executed directly.

usage() {
    cat <<'EOF'
Usage: file-upload-lib [--allow-empty] <absolute-path>

Reads content from stdin and writes it to <absolute-path>.

Behavior:
  - Creates missing parent directories automatically
  - Replaces existing file content
  - Prints a WARNING when replacing an existing file
  - Rejects empty stdin, leaving any existing file untouched

Options:
  --allow-empty         Permit empty stdin (writes a zero-byte file)
  -h, --help, h, help   Show this help message

Examples:
  printf 'hello\n' | file-upload-lib /tmp/demo.txt
  cat ./payload.json | file-upload-lib /tmp/data/payload.json
EOF
}

file_upload_from_stdin() {
    local path="$1"
    local allow_empty="${2:-0}"
    local parent_dir
    local temp_file

    if [ -z "$path" ]; then
        echo "ERROR: missing required path argument." >&2
        return 1
    fi

    # Require an absolute path to avoid ambiguous writes.
    if [[ "$path" != /* ]]; then
        echo "ERROR: path must be an absolute file path: $path" >&2
        return 1
    fi

    parent_dir="$(dirname "$path")"
    if [ ! -d "$parent_dir" ]; then
        if ! mkdir -p "$parent_dir"; then
            echo "ERROR: failed to create parent directory: $parent_dir" >&2
            return 1
        fi
    fi

    temp_file="$(mktemp "${path}.tmp.XXXXXX")" || {
        echo "ERROR: failed to create temp file for: $path" >&2
        return 1
    }

    # Always cleanup temp file on function return. "${temp_file:-}" rather than
    # "$temp_file": the RETURN trap fires after the function's locals are out of
    # scope, so the bare form is an unbound variable under the caller's "set -u"
    # -- which leaked a shell error onto every failure path, not just this
    # function's own return.
    trap 'rm -f "${temp_file:-}"' RETURN

    if ! cat > "$temp_file"; then
        echo "ERROR: failed to read stdin content for: $path" >&2
        return 1
    fi

    # Checked after stdin is staged but before the mv, so a rejected upload
    # leaves the existing file completely intact -- that is the point of the
    # guard. A producer that failed writes nothing and exits non-zero, but a
    # pipeline reports its LAST command's status, so without this an upstream
    # failure silently installed a zero-byte file over a working one.
    if [ "$allow_empty" != "1" ] && [ ! -s "$temp_file" ]; then
        echo "ERROR: refusing to write empty content to: $path" >&2
        if [ -e "$path" ]; then
            echo "       The existing file is unchanged." >&2
        fi
        echo "       If the content came from a pipe, check that the producing command succeeded." >&2
        echo "       Pass --allow-empty to write an empty file deliberately." >&2
        rm -f "$temp_file"
        trap - RETURN
        return 1
    fi

    if [ -e "$path" ]; then
        echo "WARNING: replacing existing file: $path" >&2
    fi

    if ! mv -f "$temp_file" "$path"; then
        echo "ERROR: failed to write file: $path" >&2
        return 1
    fi

    trap - RETURN
    return 0
}

cmd_upload() {
    local allow_empty=0

    if [ "${1:-}" = "--allow-empty" ]; then
        allow_empty=1
        shift
    fi

    local path="${1:-}"

    case "$path" in
        help|h|--help|-h)
            usage
            return 0
            ;;
    esac

    if [ "$#" -ne 1 ]; then
        echo "ERROR: expected exactly one path argument." >&2
        echo "Run 'file-upload-lib --help' for usage." >&2
        return 1
    fi

    if ! file_upload_from_stdin "$path" "$allow_empty"; then
        return 1
    fi

    echo "Saved content to: $path"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd_upload "$@"
fi



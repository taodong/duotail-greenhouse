#!/usr/bin/env bash
# Location: /usr/local/bin/generate-rerun-config
# Description: Emits a validated rerun-config.json document on stdout.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAME=""
NAME_GIVEN=0
declare -a FILES=()
declare -a DATA_PAIRS=()
declare -a DATA_FILES=()

usage() {
    cat <<EOF
Usage: generate-rerun-config [-ap <agent-path>] -f <task-file> [-f <task-file> ...]
                             [--name <rerun-name>] [--data KEY=value,...]
                             [--data-file <path>]

Composes a rerun-config.json document and prints it to stdout. Nothing is
written to disk -- pipe the output to upload-instruction-file to install it.

Options:
   -ap <agent-path>          Override the agent path (default: \$AGENT_PATH or /agent)
   -f, --file <name>         Task file to replay. Repeatable; the order given is
                             the execution order. At least one is required.
   --name <rerun-name>       Name the rerun, and with it its output folder.
                             Omitted from the output when not given.
   --data KEY=value,...      Context overrides merged into "data". Repeatable.
                             Dotted keys nest: user.name=Ada -> {"user":{"name":"Ada"}}
   --data-file <path>        A JSON file whose object is merged into "data".
                             Repeatable. Use it for values that are not strings.
   -h, --help, h, help       Show this help message

Every task file is checked against \$AGENT_PATH/tasks before anything is
emitted, so a mistyped name fails here rather than after rerun-tests has
started the display and the MCP services.

"data" sources are applied in this order, so the command line wins over a file:
every --data-file first, in the order given, then every --data.

Examples:
  generate-rerun-config -f test-2.md

  generate-rerun-config -f test-2.md -f test-5.md --name "login flow" \\
    --data user_email=qa+rerun@example.com \\
    | upload-instruction-file rerun-config.json
EOF
}

# Rejects a missing value and a following flag alike: "-f --name x" would
# otherwise put "--name" in the flow and report it as a missing task file --
# the same quiet misinterpretation the unknown-option branch guards against.
require_value() {
    if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
        echo "ERROR: $1 requires a value." >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        -h | --help | h | help)
            usage
            exit 0
            ;;
        -ap)
            require_value "-ap" "${2:-}"
            AGENT_PATH="$2"
            shift 2
            ;;
        -f | --file)
            require_value "$1" "${2:-}"
            FILES+=("$2")
            shift 2
            ;;
        --name)
            require_value "--name" "${2:-}"
            NAME="$2"
            NAME_GIVEN=1
            shift 2
            ;;
        --data)
            require_value "--data" "${2:-}"
            DATA_PAIRS+=("$2")
            shift 2
            ;;
        --data-file)
            require_value "--data-file" "${2:-}"
            DATA_FILES+=("$2")
            shift 2
            ;;
        *)
            # Rejected rather than ignored: stdout here is machine-read JSON
            # headed for a config file, so a mistyped flag must not quietly
            # emit a different document.
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
# shellcheck source=context-ops-lib.sh
# shellcheck source=run-qa-lib.sh
# run-qa-lib is sourced for run_qa_normalize_rerun_name only; it has no
# source-time side effects beyond two path constants, and this command
# deliberately never calls is_run_qa_active (see the design's Non-Goals).
for _name in context-ops-lib run-qa-lib; do
  _path="${_LIB}/${_name}"
  [ -f "${_path}.sh" ] && _path="${_path}.sh"
  # shellcheck disable=SC1090
  source "${_path}"
done

TASKS_DIR="${AGENT_PATH}/tasks"

# Echoes the markdown task files that could legally appear in a flow, as one
# comma-separated line for the "Available:" hint.
list_available_tasks() {
    local f out=""
    if [ -d "$TASKS_DIR" ]; then
        for f in "$TASKS_DIR"/*.md; do
            [ -e "$f" ] || continue
            [ -n "$out" ] && out+=", "
            out+="$(basename "$f")"
        done
    fi
    [ -z "$out" ] && out="(none)"
    printf '%s' "$out"
}

# ---- flow ------------------------------------------------------------------

if [ ${#FILES[@]} -eq 0 ]; then
    echo "ERROR: at least one -f <task-file> is required; \"flow\" may not be empty." >&2
    usage >&2
    exit 1
fi

for _file in "${FILES[@]}"; do
    # selectRerunTasks matches by basename, so a path would be written verbatim
    # and then fail at rerun time as "not found in ./tasks/" -- an error that
    # names the wrong problem.
    case "$_file" in
        */*)
            echo "ERROR: -f takes a bare task filename, not a path: $_file" >&2
            echo "       Flow entries are matched by basename against ${TASKS_DIR}." >&2
            exit 1
            ;;
    esac
    if [ ! -f "${TASKS_DIR}/${_file}" ]; then
        echo "ERROR: no such task file: $_file" >&2
        echo "  Available: $(list_available_tasks)" >&2
        exit 1
    fi
done

# Replaying one task twice is legal, so this warns rather than fails -- but a
# repeat is more often a typo than an intention, and silence would hide it.
# Newline-delimited membership with a whole-line match, not an associative
# array: the host runs bash 3.2. Not comma-delimited -- a comma is legal in a
# filename, and joining on one made "b,a.md" report an unrelated "a.md" as a
# duplicate.
_seen=""
_warned=""
for _file in "${FILES[@]}"; do
    if printf '%s\n' "$_seen" | grep -Fxq -- "$_file"; then
        if ! printf '%s\n' "$_warned" | grep -Fxq -- "$_file"; then
            echo "⚠️  Duplicate task file in flow: ${_file} (it will be replayed more than once)" >&2
            _warned="${_warned}
${_file}"
        fi
    else
        _seen="${_seen}
${_file}"
    fi
done

# ---- name ------------------------------------------------------------------

if [ "$NAME_GIVEN" -eq 1 ]; then
    # Three checks in the agent's own order: the loader rejects a blank name,
    # then resolveRerunOutputDir rejects one that normalizes to nothing and one
    # that normalizes to a plain number. "!!!" passes the first and fails the
    # second, so collapsing them would report the wrong reason.
    if [ -z "$(context_ops_trim "$NAME")" ]; then
        echo "ERROR: --name must be a non-empty string." >&2
        exit 1
    fi

    # run_qa_normalize_rerun_name is the repo's single mirror of the agent's
    # normalizeRerunName, and returns 1 when nothing survives. Reused rather
    # than reimplemented: a sed-based copy is line-oriented and would leave a
    # newline uncollapsed, predicting a folder the agent never creates.
    if ! NORMALIZED="$(run_qa_normalize_rerun_name "$NAME")"; then
        echo "ERROR: --name normalizes to an empty string: \"$NAME\"" >&2
        echo "       Names keep only a-z, 0-9, \"_\" and \"-\"; everything else is stripped." >&2
        exit 1
    fi
    if [[ "$NORMALIZED" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --name normalizes to \"$NORMALIZED\", a plain number, which would collide in form with the auto-numbered rerun-N folder scheme. Choose a name with at least one non-digit character." >&2
        exit 1
    fi

    # Reported because normalization is lossy: this is the folder rerun-tests
    # will create and the name check-test-result --rerun will accept, neither
    # of which is obvious from the raw name.
    RERUN_DIR="${AGENT_PATH}/outputs/rerun-${NORMALIZED}"
    if [ -d "$RERUN_DIR" ]; then
        # A warning, not an error: a named rerun whose folder exists is fatal to
        # rerun-tests, but the user may be about to remove it, and this command
        # must not make its exit status depend on output state it does not own.
        echo "⚠️  Rerun output folder already exists: ${RERUN_DIR}" >&2
        echo "    rerun-tests will abort unless it is removed or a different --name is used." >&2
    else
        echo "ℹ️  Rerun output folder will be: outputs/rerun-${NORMALIZED}/" >&2
    fi
fi

# ---- data ------------------------------------------------------------------

DATA_JSON="{}"

for _df in "${DATA_FILES[@]+"${DATA_FILES[@]}"}"; do
    if [ ! -f "$_df" ]; then
        echo "ERROR: --data-file not found: $_df" >&2
        exit 1
    fi
    # Same "exactly one JSON object" test get-test-report applies to a results
    # file, and for the same reasons: "jq empty" passes on a zero-byte file, and
    # jq -e reports only the LAST value of a concatenated stream. The object
    # check also rejects the bare array/string/null that loadRerunConfig rejects.
    if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$_df" >/dev/null 2>&1; then
        echo "ERROR: --data-file must hold exactly one JSON object: $_df" >&2
        exit 1
    fi
    DATA_JSON="$(jq -n --argjson base "$DATA_JSON" --slurpfile add "$_df" '$base * $add[0]')"
done

# Applied after the files so an inline override beats a stored default. The
# prefix is cleared explicitly: preset-context sets it to "data" to nest its
# values, while here the pairs *are* the data object.
# shellcheck disable=SC2034 # read by context_ops_build_path_json in the sourced lib
CONTEXT_PATH_PREFIX=""
for _pairs in "${DATA_PAIRS[@]+"${DATA_PAIRS[@]}"}"; do
    # Checked: context_ops_apply_pairs returns 1 when a dotted key collides with
    # a non-object value already in "data" (--data-file '{"user":"ada"}' plus
    # --data user.name=Ada). Unchecked, the empty result reached --argjson and
    # surfaced as a second, wrong-layer jq error with exit 2.
    if ! DATA_JSON="$(context_ops_apply_pairs "$DATA_JSON" "$_pairs")" || [ -z "$DATA_JSON" ]; then
        echo "ERROR: could not build \"data\" from: $_pairs" >&2
        exit 1
    fi
done

# ---- emit ------------------------------------------------------------------

# One jq call, no temp file. --args carries the filenames as positional
# arguments so none can be read as part of the filter. "name" and "data" are
# omitted rather than emitted empty: loadRerunConfig treats both as optional,
# and "data": {} would misrepresent a config that overrides nothing -- the same
# "no null placeholders" convention get-test-report follows for "reruns".
# shellcheck disable=SC2016 # $name/$data/$ARGS are jq variables, not shell expansions
jq -n --arg name "$NAME" --argjson data "$DATA_JSON" --args '
      (if $name != "" then {name: $name} else {} end)
    + {flow: [$ARGS.positional[] | {file: .}]}
    + (if ($data | length) > 0 then {data: $data} else {} end)
' "${FILES[@]}"

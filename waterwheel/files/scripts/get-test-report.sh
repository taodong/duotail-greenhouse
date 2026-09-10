#!/usr/bin/env bash
# Location: /usr/local/bin/get-test-report
# Description: Prints the full run's results and every rerun's results as one JSON document.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="full"

usage() {
    cat <<EOF
Usage: get-test-report [-ap <agent-path>] [--list-tests | --list-results]

Prints the full run's results and every rerun's results as one JSON document.

Options:
   -ap <agent-path>          Override the agent path (default: \$AGENT_PATH or /agent)
   --list-tests              Instead of the full report, list only the name and file of
                             each test in the run's results. Rerun folders are not read.
   --list-results            Instead of the full report, list only test_name, test_type,
                             status and exit_condition for the run and each rerun.
   -h, --help, h, help       Show this help message

--list-tests and --list-results are mutually exclusive.
EOF
}

while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        -h | --help | h | help)
            usage
            exit 0
            ;;
        -ap)
            if [ -z "${2:-}" ]; then
                echo "ERROR: -ap requires an agent path." >&2
                exit 1
            fi
            AGENT_PATH="$2"
            shift 2
            ;;
        --list-tests | --list-results)
            # One MODE variable rather than two booleans, so the exclusivity
            # check is a comparison against what is already set. Repeating the
            # same flag is harmless; only the conflicting pair is rejected.
            _requested="${1#--list-}"
            if [ "$MODE" != "full" ] && [ "$MODE" != "$_requested" ]; then
                echo "ERROR: --list-tests and --list-results are mutually exclusive." >&2
                usage >&2
                exit 1
            fi
            MODE="$_requested"
            shift
            ;;
        *)
            # Rejected rather than ignored: stdout here is machine-read JSON, so
            # a mistyped flag must not quietly emit a different document.
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Source shared libs co-located with this script (repo scripts/ in dev,
# /usr/local/bin in the container). The .sh suffix only exists in dev.
# shellcheck source=run-qa-lib.sh
for _name in run-qa-lib; do
  _path="${_LIB}/${_name}"
  [ -f "${_path}.sh" ] && _path="${_path}.sh"
  # shellcheck disable=SC1090
  source "${_path}"
done

if is_run_qa_active; then
    echo "ERROR: Testing is in progress ($(run_qa_session_mode) pid: $RUN_QA_ACTIVE_PID). The test report isn't available until the run completes." >&2
    exit 1
fi

RESULTS_FILE="${AGENT_PATH}/outputs/test-results.json"

# "jq empty" is the parse check. Without it a truncated results file -- possible
# if the container was killed mid-write -- would abort under "set -e" with a raw
# jq parse error instead of this message.
if [ ! -f "$RESULTS_FILE" ] || ! jq empty "$RESULTS_FILE" 2>/dev/null; then
    echo "ERROR: test report isn't available." >&2
    exit 1
fi

# Keeps only the four run-level fields, in source-file order, and drops any the
# source omits -- a regular run has no test_name, and "no null placeholders" is
# the convention writeTestResults itself follows. Constructing
# {test_name, test_type, status, exit_condition} instead would materialize
# "test_name": null on every regular run.
RUN_SUMMARY_FILTER='with_entries(select(.key == "test_name" or .key == "test_type" or .key == "status" or .key == "exit_condition"))'

# Echoes the rerun name a folder maps to: its basename without the "rerun-"
# prefix. This is the value check-test-result --rerun accepts, and is distinct
# from the file's own test_name, which is the raw un-normalized config name (or
# the folder basename *with* its prefix for an unnamed rerun).
rerun_name_of() {
    local name
    name="$(basename "$1")"
    printf '%s\n' "${name#rerun-}"
}

# Emits one JSON object per rerun that has parseable results, applying $1 as the
# jq filter; warns on stderr and skips the rest. Always returns 0, so a skipped
# rerun does not trip pipefail in the pipelines below.
emit_rerun_docs() {
    local filter="$1" dir name file
    while IFS= read -r dir; do
        name="$(rerun_name_of "$dir")"
        file="${dir}/test-results.json"
        if [ ! -f "$file" ] || ! jq empty "$file" 2>/dev/null; then
            echo "⚠️  Skipping rerun \"${name}\": no test-results.json" >&2
            continue
        fi
        jq --arg name "$name" "$filter" "$file"
    done < <(run_qa_list_rerun_dirs "$AGENT_PATH")
    return 0
}

case "$MODE" in
    tests)
        # Only the parent run; rerun folders are never opened. The "// []" guard
        # keeps a results-less file yielding [] rather than a jq error.
        jq '[ (.results // [])[] | {name, file} ]' "$RESULTS_FILE"
        ;;
    results)
        {
            jq "$RUN_SUMMARY_FILTER" "$RESULTS_FILE"
            emit_rerun_docs "$RUN_SUMMARY_FILTER"
        } | jq -n '[inputs]'
        ;;
    full)
        # jq -n with "inputs" slurps the piped per-rerun objects, so the whole
        # document is assembled in a single jq call with no temp file. The
        # trailing "+ (if ... )" is what omits "reruns" rather than emitting [].
        # shellcheck disable=SC2016 # "$name" is a jq variable bound by --arg
        # in emit_rerun_docs, not a shell expansion.
        emit_rerun_docs '{name: $name, test_result: .}' \
            | jq -n --slurpfile run "$RESULTS_FILE" '
                [inputs] as $reruns
                | {test_run: $run[0]}
                  + (if ($reruns | length) > 0 then {reruns: $reruns} else {} end)
            '
        ;;
esac

#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/get-test-report.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fail() {
  echo "$1" >&2
  exit 1
}

# Fixtures carry test_type (and test_name on reruns) so the run-level projection
# is exercised against the real post-"run identity" schema.
write_run() {
  cat > "$1/test-results.json" <<EOF
{
  "results": [
    { "name": "Wiki Banner", "file": "test-wikipedia-english.md", "id": "3",
      "status": "success", "result": "ok" },
    { "name": "Login flow", "file": "test-2.md", "id": "4",
      "status": "failed", "result": "boom", "node": 1, "required": [0] }
  ],
  "starts": "2026-09-09T00:00:00Z", "ends": "2026-09-09T00:01:00Z",
  "total_duration_sec": 60, "status": "complete",
  "exit_condition": "1 test failed", "test_type": "regular"
}
EOF
}

write_rerun() {
  # $1 dir, $2 test_name, $3 status, $4 exit_condition, $5 task file
  cat > "$1/test-results.json" <<EOF
{
  "results": [
    { "name": "Login flow", "file": "$5", "id": "4", "status": "failed", "result": "x" }
  ],
  "starts": "2026-09-09T00:02:00Z", "ends": "2026-09-09T00:03:00Z",
  "total_duration_sec": 60, "status": "$3",
  "exit_condition": "$4", "test_type": "rerun", "test_name": "$2"
}
EOF
}

agent="$tmpdir/agent"
mkdir -p "$agent/outputs"
write_run "$agent/outputs"

echo '== full report with no reruns omits the reruns key =='
solo=$(bash "$script" -ap "$agent")
printf '%s' "$solo" | jq -e '.test_run.exit_condition == "1 test failed"' > /dev/null \
  || fail 'expected test_run.exit_condition from the run results'
printf '%s' "$solo" | jq -e 'has("reruns") | not' > /dev/null \
  || fail 'expected no reruns key when no rerun folder exists'

echo '== --list-results with no reruns is a one-element array =='
bash "$script" -ap "$agent" --list-results | jq -e 'length == 1' > /dev/null \
  || fail 'expected a single run summary'

echo '== --list-tests lists name and file from the run results =='
tests_out=$(bash "$script" -ap "$agent" --list-tests)
printf '%s' "$tests_out" | jq -e 'length == 2' > /dev/null \
  || fail 'expected two tests listed'
printf '%s' "$tests_out" | jq -e '.[1] == {name: "Login flow", file: "test-2.md"}' > /dev/null \
  || fail 'expected {name, file} pairs in results order'
printf '%s' "$tests_out" | jq -e 'all(keys == ["file", "name"])' > /dev/null \
  || fail 'expected only name and file keys'

echo '== --list-tests on a results-less file yields [] =='
solo_agent="$tmpdir/solo"
mkdir -p "$solo_agent/outputs"
printf '{"status":"incomplete"}' > "$solo_agent/outputs/test-results.json"
bash "$script" -ap "$solo_agent" --list-tests | jq -e '. == []' > /dev/null \
  || fail 'expected [] when the results key is absent'

# Two reruns plus one that never wrote results. mtimes are set explicitly so the
# ordering assertion tests mtime ordering, not creation order.
mkdir -p "$agent/outputs/rerun-login_flow" "$agent/outputs/rerun-1" "$agent/outputs/rerun-empty"
write_rerun "$agent/outputs/rerun-login_flow" "login flow" "complete" "all tests passed" "test-2.md"
write_rerun "$agent/outputs/rerun-1" "rerun-1" "incomplete" "1 test failed" "test-2.md"
touch -t 202609090002 "$agent/outputs/rerun-login_flow"
touch -t 202609090004 "$agent/outputs/rerun-1"
touch -t 202609090006 "$agent/outputs/rerun-empty"

echo '== full report nests each rerun under its folder-derived name, oldest first =='
full=$(bash "$script" -ap "$agent" 2> "$tmpdir/full.err")
printf '%s' "$full" | jq -e '[.reruns[].name] == ["login_flow", "1"]' > /dev/null \
  || fail 'expected reruns named by folder basename, oldest first by mtime'
printf '%s' "$full" | jq -e '.reruns[0].test_result.exit_condition == "all tests passed"' > /dev/null \
  || fail "expected the rerun's own results nested under test_result"
grep -Fq 'Skipping rerun "empty"' "$tmpdir/full.err" \
  || fail 'expected a stderr warning naming the resultless rerun'

echo '== the resultless rerun is absent from stdout =='
printf '%s' "$full" | jq -e '[.reruns[].name] | index("empty") == null' > /dev/null \
  || fail 'expected the resultless rerun to be excluded'

echo '== a truncated rerun results file is skipped like a missing one =='
printf '{"results":[' > "$agent/outputs/rerun-empty/test-results.json"
trunc=$(bash "$script" -ap "$agent" 2> "$tmpdir/trunc.err")
printf '%s' "$trunc" | jq -e '[.reruns[].name] == ["login_flow", "1"]' > /dev/null \
  || fail 'expected an unparseable rerun to be skipped, not to abort'
grep -Fq 'Skipping rerun "empty": unreadable' "$tmpdir/trunc.err" \
  || fail 'expected the warning to name corruption, not a missing file'

# "jq empty" exits 0 on a zero-byte file, so this case previously fell through
# the skip branch and dropped the rerun with no warning at all -- and in full
# mode that is indistinguishable from no rerun ever having run.
echo '== an empty rerun results file is skipped with a warning =='
: > "$agent/outputs/rerun-empty/test-results.json"
empty_rerun=$(bash "$script" -ap "$agent" 2> "$tmpdir/emptyrerun.err")
printf '%s' "$empty_rerun" | jq -e '[.reruns[].name] == ["login_flow", "1"]' > /dev/null \
  || fail 'expected an empty rerun results file to be skipped'
grep -Fq 'Skipping rerun "empty"' "$tmpdir/emptyrerun.err" \
  || fail 'expected a stderr warning for the empty rerun results file'
rm -f "$agent/outputs/rerun-empty/test-results.json"

echo '== a missing rerun results file says so, not "unreadable" =='
missing_err=$(bash "$script" -ap "$agent" 2>&1 >/dev/null || true)
printf '%s' "$missing_err" | grep -Fq 'Skipping rerun "empty": no test-results.json' \
  || fail 'expected a missing file to be reported as missing'

echo '== --list-results summarizes the run then each rerun, run-level fields only =='
results_out=$(bash "$script" -ap "$agent" --list-results 2>/dev/null)
printf '%s' "$results_out" | jq -e 'length == 3' > /dev/null \
  || fail 'expected the run plus two reruns'
printf '%s' "$results_out" | jq -e 'all(has("results") | not)' > /dev/null \
  || fail 'expected no results array in any summary'
printf '%s' "$results_out" | jq -e '.[0] | has("test_name") | not' > /dev/null \
  || fail 'expected a regular run to carry no test_name key'
printf '%s' "$results_out" | jq -e '.[0].test_type == "regular"' > /dev/null \
  || fail 'expected the run to come first'
# test_name is the raw config name, not the normalized folder suffix.
printf '%s' "$results_out" | jq -e '[.[1:][].test_name] == ["login flow", "rerun-1"]' > /dev/null \
  || fail 'expected verbatim test_name values, oldest rerun first'
printf '%s' "$results_out" | jq -e '.[2].status == "incomplete"' > /dev/null \
  || fail 'expected the run-level status, not a per-test status'

echo '== the two list flags are mutually exclusive =='
if bash "$script" -ap "$agent" --list-tests --list-results > /dev/null 2>&1; then
  fail 'expected --list-tests --list-results to be rejected'
fi
excl_err=$(bash "$script" -ap "$agent" --list-tests --list-results 2>&1 >/dev/null || true)
printf '%s' "$excl_err" | grep -Fq 'mutually exclusive' \
  || fail 'expected an exclusivity message on stderr'

echo '== repeating the same list flag is accepted =='
bash "$script" -ap "$agent" --list-tests --list-tests | jq -e 'length == 2' > /dev/null \
  || fail 'expected a repeated flag to behave like a single one'

echo '== a missing results file reports that no report is available =='
empty_agent="$tmpdir/empty"
mkdir -p "$empty_agent/outputs"
if bash "$script" -ap "$empty_agent" > "$tmpdir/empty.out" 2> "$tmpdir/empty.err"; then
  fail 'expected a non-zero exit when the run has no results'
fi
[ ! -s "$tmpdir/empty.out" ] || fail 'expected empty stdout when no report is available'
grep -Fq "test report isn't available" "$tmpdir/empty.err" \
  || fail 'expected the not-available message on stderr'

echo '== a truncated run results file is reported the same way =='
printf '{"results":[' > "$empty_agent/outputs/test-results.json"
if bash "$script" -ap "$empty_agent" > "$tmpdir/trunc.out" 2>/dev/null; then
  fail 'expected a non-zero exit for an unparseable results file'
fi
[ ! -s "$tmpdir/trunc.out" ] || fail 'expected empty stdout for an unparseable results file'

# An empty file is what a container killed mid-write leaves behind, and it is
# the case "jq empty" silently accepted: full mode emitted {"test_run": null}
# with exit 0, and --list-tests emitted nothing at all -- stdout that is not
# JSON, from a command whose contract is that stdout is always JSON.
echo '== an empty run results file is not a valid report, in any mode =='
for mode in '' '--list-tests' '--list-results'; do
  : > "$empty_agent/outputs/test-results.json"
  # shellcheck disable=SC2086 # deliberate word splitting: "" must pass no flag
  if bash "$script" -ap "$empty_agent" $mode > "$tmpdir/zero.out" 2>/dev/null; then
    fail "expected a non-zero exit for an empty results file (mode: ${mode:-full})"
  fi
  [ ! -s "$tmpdir/zero.out" ] \
    || fail "expected empty stdout for an empty results file (mode: ${mode:-full})"
done

echo '== a file holding a bare JSON value is not a valid report =='
printf 'null' > "$empty_agent/outputs/test-results.json"
if bash "$script" -ap "$empty_agent" > /dev/null 2>&1; then
  fail 'expected a non-zero exit for a results file holding a bare null'
fi

echo '== an unknown option is rejected =='
if bash "$script" -ap "$agent" --list-reruns > /dev/null 2>&1; then
  fail 'expected an unknown option to be rejected'
fi

echo '== -ap requires a value =='
if bash "$script" -ap > /dev/null 2>&1; then
  fail 'expected -ap with no value to be rejected'
fi

echo '== -ap rejects a following flag instead of consuming it =='
if bash "$script" -ap --list-tests > /dev/null 2>&1; then
  fail 'expected -ap followed by a flag to be rejected'
fi
ap_err=$(bash "$script" -ap --list-tests 2>&1 >/dev/null || true)
printf '%s' "$ap_err" | grep -Fq 'requires an agent path' \
  || fail 'expected -ap to report a missing path, not a missing report'

echo 'get-test-report smoke checks passed'

#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/waterwheel/files/scripts/generate-rerun-config.sh"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fail() {
  echo "$1" >&2
  exit 1
}

agent="$tmpdir/agent"
mkdir -p "$agent/tasks"
touch "$agent/tasks/test-2.md" "$agent/tasks/test-5.md" "$agent/tasks/test-wikipedia-english.md"

echo '== minimal: one -f, no name key, no data key =='
min=$(bash "$script" -ap "$agent" -f test-2.md)
printf '%s' "$min" | jq -e '. == {flow: [{file: "test-2.md"}]}' > /dev/null \
  || fail 'expected exactly {"flow":[{"file":"test-2.md"}]}'
# Omitted, not emitted empty: loadRerunConfig treats both as optional, and
# "data": {} would misrepresent a config that overrides nothing.
printf '%s' "$min" | jq -e 'has("name") | not' > /dev/null \
  || fail 'expected no name key when --name was not given'
printf '%s' "$min" | jq -e 'has("data") | not' > /dev/null \
  || fail 'expected no data key when no data was given'

echo '== repeated -f preserves command-line order =='
bash "$script" -ap "$agent" -f test-5.md -f test-2.md \
  | jq -e '[.flow[].file] == ["test-5.md", "test-2.md"]' > /dev/null \
  || fail 'expected flow order to follow the -f order, not sorted'

echo '== flow entries carry file and nothing else =='
# The loader's flow.map reconstructs {file} and silently drops every other key,
# so emitting anything more would be dead weight in the file.
bash "$script" -ap "$agent" -f test-2.md -f test-5.md \
  | jq -e 'all(.flow[]; keys == ["file"])' > /dev/null \
  || fail 'expected each flow entry to hold only a file key'

echo '== --name is emitted raw, not normalized =='
# resolveRerunTestName writes the un-normalized name into test-results.json as
# test_name; only the folder carries the normalized form.
bash "$script" -ap "$agent" -f test-2.md --name "login flow" 2>/dev/null \
  | jq -e '.name == "login flow"' > /dev/null \
  || fail 'expected the raw name verbatim in the document'

echo '== --name reports the folder it will resolve to, on stderr =='
name_err=$(bash "$script" -ap "$agent" -f test-2.md --name "Login Flow" 2>&1 >/dev/null)
printf '%s' "$name_err" | grep -Fq 'outputs/rerun-login_flow/' \
  || fail 'expected the normalized folder name on stderr'

echo '== name normalization matches the agent, case for case =='
# Expected values produced by running the agent's own normalizeRerunName
# (ww-agent/src/utils/rerun-output-dir.ts) over these inputs. This table is the
# guard against the two implementations drifting: the folder the command
# predicts on stderr must be the folder rerun-qa actually creates.
while IFS='|' read -r raw expected; do
  [ -n "$raw" ] || continue
  bash "$script" -ap "$agent" -f test-2.md --name "$raw" > /dev/null 2> "$tmpdir/norm.err" \
    || fail "expected --name \"$raw\" to be accepted"
  got=$(sed -n 's/.*outputs\/rerun-\(.*\)\/.*/\1/p' "$tmpdir/norm.err")
  [ "$got" = "$expected" ] \
    || fail "normalization drift for \"$raw\": expected \"$expected\", got \"$got\""
done <<'CASES'
login flow|login_flow
Login Flow|login_flow
  padded  name  |padded_name
Nightly Run #3|nightly_run_3
login__flow|login__flow
a-b_c|a-b_c
UPPER|upper
multi   space|multi_space
1a|1a
héllo wörld|hllo_wrld
re:run@2024|rerun2024
...dots...|dots
CASES

echo '== --data nests dotted keys and strips quotes from a quoted value =='
data_out=$(bash "$script" -ap "$agent" -f test-2.md --data 'env=staging,user.name="Ada L"')
printf '%s' "$data_out" | jq -e '.data == {env: "staging", user: {name: "Ada L"}}' > /dev/null \
  || fail 'expected dotted keys to nest and quotes to be stripped'

echo '== --data-file merges, and keeps non-string values =='
printf '{"retry_count":3,"env":"dev","flags":["a","b"]}' > "$tmpdir/df.json"
df_out=$(bash "$script" -ap "$agent" -f test-2.md --data-file "$tmpdir/df.json")
printf '%s' "$df_out" | jq -e '.data.retry_count == 3 and (.data.flags | type) == "array"' > /dev/null \
  || fail 'expected non-string values to survive from a data file'

echo '== --data overrides a colliding key from --data-file =='
# Documented precedence: files first as the base, then the command line on top.
bash "$script" -ap "$agent" -f test-2.md --data-file "$tmpdir/df.json" --data env=staging \
  | jq -e '.data.env == "staging" and .data.retry_count == 3' > /dev/null \
  || fail 'expected --data to win over --data-file, leaving other keys intact'

echo '== repeated --data-file accumulates, later wins =='
printf '{"env":"prod","extra":1}' > "$tmpdir/df2.json"
bash "$script" -ap "$agent" -f test-2.md --data-file "$tmpdir/df.json" --data-file "$tmpdir/df2.json" \
  | jq -e '.data.env == "prod" and .data.retry_count == 3 and .data.extra == 1' > /dev/null \
  || fail 'expected later data files to override earlier ones and accumulate'

echo '== key order is name, flow, data =='
bash "$script" -ap "$agent" -f test-2.md --name rerun-a --data k=v 2>/dev/null \
  | jq -e 'keys_unsorted == ["name", "flow", "data"]' > /dev/null \
  || fail 'expected name, flow, data in that order'

echo '== output is exactly one JSON document =='
bash "$script" -ap "$agent" -f test-2.md --name rerun-a --data k=v 2>/dev/null > "$tmpdir/doc.out"
jq -e -s 'length == 1' "$tmpdir/doc.out" > /dev/null \
  || fail 'expected exactly one top-level document'

echo '== a duplicate -f warns but still emits =='
dup=$(bash "$script" -ap "$agent" -f test-2.md -f test-2.md 2> "$tmpdir/dup.err")
printf '%s' "$dup" | jq -e '[.flow[].file] == ["test-2.md", "test-2.md"]' > /dev/null \
  || fail 'expected the duplicate to be kept -- replaying a task twice is legal'
grep -Fq 'Duplicate task file in flow: test-2.md' "$tmpdir/dup.err" \
  || fail 'expected a stderr warning naming the duplicate'
# Warned once per duplicated value, not once per extra occurrence.
[ "$(grep -c 'Duplicate task file' "$tmpdir/dup.err")" -eq 1 ] \
  || fail 'expected exactly one duplicate warning'

echo '== an existing rerun folder warns but still emits =='
mkdir -p "$agent/outputs/rerun-login_flow"
existing=$(bash "$script" -ap "$agent" -f test-2.md --name "login flow" 2> "$tmpdir/exists.err")
printf '%s' "$existing" | jq -e '.name == "login flow"' > /dev/null \
  || fail 'expected valid JSON despite the existing folder'
grep -Fq 'already exists' "$tmpdir/exists.err" \
  || fail 'expected a stderr warning about the existing rerun folder'
rmdir "$agent/outputs/rerun-login_flow"

echo '== warnings stay off stdout =='
# The whole point of the stdout contract: this pipes into upload-instruction-file.
bash "$script" -ap "$agent" -f test-2.md -f test-2.md 2>/dev/null | jq -e . > /dev/null \
  || fail 'expected stdout to parse as JSON with warnings suppressed'

echo '== no -f is rejected =='
if bash "$script" -ap "$agent" > /dev/null 2>&1; then
  fail 'expected a missing -f to be rejected -- flow may not be empty'
fi

echo '== an unknown task file is named, and the available ones listed =='
unknown_err=$(bash "$script" -ap "$agent" -f typo.md 2>&1 >/dev/null || true)
printf '%s' "$unknown_err" | grep -Fq 'no such task file: typo.md' \
  || fail 'expected the error to name the missing file'
printf '%s' "$unknown_err" | grep -Fq 'test-wikipedia-english.md' \
  || fail 'expected the available task files to be listed'

echo '== -f with a path is rejected =='
# selectRerunTasks matches by basename, so a path fails at rerun time with an
# error that names the wrong problem.
if bash "$script" -ap "$agent" -f sub/test-2.md > /dev/null 2>&1; then
  fail 'expected a path-valued -f to be rejected'
fi

echo '== a name normalizing to empty or to a plain number is rejected =='
empty_name_err=$(bash "$script" -ap "$agent" -f test-2.md --name '!!!' 2>&1 >/dev/null || true)
printf '%s' "$empty_name_err" | grep -Fq 'normalizes to an empty string' \
  || fail 'expected the empty-normalization error'
num_name_err=$(bash "$script" -ap "$agent" -f test-2.md --name 12 2>&1 >/dev/null || true)
printf '%s' "$num_name_err" | grep -Fq 'plain number' \
  || fail 'expected the plain-number error, not the empty-normalization one'

echo '== a --name starting with "-" is rejected, not consumed =='
# A consequence of the repo-wide "value flags reject a following flag" rule.
# The agent would accept such a name; this command cannot express it.
if bash "$script" -ap "$agent" -f test-2.md --name -nightly > /dev/null 2>&1; then
  fail 'expected a dash-prefixed name to be rejected'
fi

echo '== a blank name is rejected before normalization is considered =='
if bash "$script" -ap "$agent" -f test-2.md --name '   ' > /dev/null 2>&1; then
  fail 'expected a whitespace-only name to be rejected'
fi

echo '== a bad --data-file is rejected =='
if bash "$script" -ap "$agent" -f test-2.md --data-file "$tmpdir/nope.json" > /dev/null 2>&1; then
  fail 'expected a missing data file to be rejected'
fi
printf '{"a":' > "$tmpdir/bad.json"
if bash "$script" -ap "$agent" -f test-2.md --data-file "$tmpdir/bad.json" > /dev/null 2>&1; then
  fail 'expected a malformed data file to be rejected'
fi
# loadRerunConfig rejects a data that is null or an array; so does this.
printf '[1,2]' > "$tmpdir/arr.json"
if bash "$script" -ap "$agent" -f test-2.md --data-file "$tmpdir/arr.json" > /dev/null 2>&1; then
  fail 'expected a data file holding an array to be rejected'
fi
printf 'null' > "$tmpdir/null.json"
if bash "$script" -ap "$agent" -f test-2.md --data-file "$tmpdir/null.json" > /dev/null 2>&1; then
  fail 'expected a data file holding a bare null to be rejected'
fi
# jq -e reports only the LAST value of a concatenated stream, so this slipped
# through an unslurped check and silently used the second object.
printf '{"a":1}\n{"b":2}\n' > "$tmpdir/multi.json"
if bash "$script" -ap "$agent" -f test-2.md --data-file "$tmpdir/multi.json" > /dev/null 2>&1; then
  fail 'expected concatenated JSON values to be rejected'
fi

echo '== an unknown option is rejected =='
if bash "$script" -ap "$agent" -f test-2.md --list-tests > /dev/null 2>&1; then
  fail 'expected an unknown option to be rejected'
fi

echo '== value flags reject a missing value and a following flag =='
for flags in "-f" "--name" "--data" "--data-file" "-ap"; do
  # shellcheck disable=SC2086 # deliberate word splitting
  if bash "$script" -ap "$agent" $flags > /dev/null 2>&1; then
    fail "expected $flags with no value to be rejected"
  fi
  # shellcheck disable=SC2086 # deliberate word splitting
  if bash "$script" -ap "$agent" $flags --name x > /dev/null 2>&1; then
    fail "expected $flags followed by a flag to be rejected"
  fi
done

echo '== every failure exits non-zero with empty stdout =='
# A partial document would be piped straight into upload-instruction-file.
while IFS='|' read -r label args; do
  [ -n "$label" ] || continue
  # shellcheck disable=SC2086 # deliberate word splitting
  if bash "$script" -ap "$agent" $args > "$tmpdir/err.out" 2>/dev/null; then
    fail "expected a non-zero exit: $label"
  fi
  [ ! -s "$tmpdir/err.out" ] || fail "expected empty stdout: $label"
done <<'CASES'
no flow|
unknown task|-f typo.md
path task|-f sub/test-2.md
empty name|-f test-2.md --name !!!
numeric name|-f test-2.md --name 12
unknown option|-f test-2.md --nope
CASES

echo '== help exits 0 and prints usage =='
bash "$script" -h | grep -Fq 'Usage: generate-rerun-config' \
  || fail 'expected -h to print usage'
for h in --help h help; do
  bash "$script" "$h" > /dev/null || fail "expected $h to exit 0"
done

echo 'generate-rerun-config smoke checks passed'

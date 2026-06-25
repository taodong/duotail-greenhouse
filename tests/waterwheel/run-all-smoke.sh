#!/usr/bin/env bash
set -euo pipefail

repo=/Users/taodong/Work/code/duotail-greenhouse
tests_dir="$repo/tests/waterwheel"

echo '== run manage-test-files smoke =='
bash "$tests_dir/manage-test-files-smoke.sh"

echo '== run preset-context smoke =='
bash "$tests_dir/preset-context-smoke.sh"

echo '== run file-upload-lib smoke =='
bash "$tests_dir/file-upload-lib-smoke.sh"

echo 'all smoke checks passed'


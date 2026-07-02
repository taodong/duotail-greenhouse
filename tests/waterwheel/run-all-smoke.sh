#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tests_dir="$repo/tests/waterwheel"

echo '== run manage-test-files smoke =='
bash "$tests_dir/manage-test-files-smoke.sh"

echo '== run preset-context smoke =='
bash "$tests_dir/preset-context-smoke.sh"

echo '== run file-upload-lib smoke =='
bash "$tests_dir/file-upload-lib-smoke.sh"

echo '== run set-domain-permission smoke =='
bash "$tests_dir/set-domain-permission-smoke.sh"

echo '== run upload-instruction-file smoke =='
bash "$tests_dir/upload-instruction-file-smoke.sh"

echo '== run upload-test-task smoke =='
bash "$tests_dir/upload-test-task-smoke.sh"

echo '== run enable-test-on-host smoke =='
bash "$tests_dir/enable-test-on-host-smoke.sh"

echo '== run reset-test-config smoke =='
bash "$tests_dir/reset-test-config-smoke.sh"

echo '== run customize-playwright-config smoke =='
bash "$tests_dir/customize-playwright-config-smoke.sh"

echo 'all smoke checks passed'


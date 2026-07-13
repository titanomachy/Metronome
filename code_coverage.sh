#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

nim="${NIM:-nim}"
coverage_flags=(
  --debugger:native
  --passC:--coverage
  --passL:--coverage
)

echo "Cleaning previous coverage output..."
rm -rf "$repo_root/nimcache" "$repo_root/coverage_html"
rm -f "$repo_root/coverage.info"

echo "Compiling and running tests with coverage instrumentation..."
"$nim" c "${coverage_flags[@]}" --nimcache:nimcache/cron -r tests/test_cron.nim
"$nim" c "${coverage_flags[@]}" --nimcache:nimcache/scheduler -r tests/test_scheduler.nim
"$nim" c "${coverage_flags[@]}" --nimcache:nimcache/beater -r tests/test_beater.nim
"$nim" c "${coverage_flags[@]}" --nimcache:nimcache/timezones -r tests/test_timezones.nim

echo "Capturing and filtering coverage..."
lcov --ignore-errors inconsistent,unused,mismatch,missing,source,empty,gcov,range --filter range --capture --directory nimcache --output-file coverage.info
lcov --ignore-errors inconsistent,unused,mismatch,missing,source,empty,gcov --extract coverage.info "$repo_root/src/*" --output-file coverage.info

echo "Generating HTML report and coverage badge..."
genhtml --ignore-errors inconsistent,corrupt,range coverage.info --output-directory coverage_html
scripts/coverage_badge.sh coverage.info docs/coverage.svg

echo "Coverage report written to coverage_html/index.html"

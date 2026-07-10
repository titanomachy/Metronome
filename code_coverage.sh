#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

lcov --ignore-errors inconsistent,unused,mismatch,missing,source,empty,gcov,range --filter range --capture --directory nimcache --output-file coverage.info
lcov --ignore-errors inconsistent,unused,mismatch,missing,source,empty,gcov --extract coverage.info "$repo_root/src/*" --output-file coverage.info
genhtml --ignore-errors range coverage.info --output-directory coverage_html
scripts/coverage_badge.sh coverage.info docs/coverage.svg

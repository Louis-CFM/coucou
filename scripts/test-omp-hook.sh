#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-omp-hook.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/OmpHookSupport.swift \
    tests/OmpHookTests.swift -o "$TEST_DIR/omp-hook-tests"
"$TEST_DIR/omp-hook-tests"

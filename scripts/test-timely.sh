#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-timely.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library NotchBuddy/Sources/App/TimelyAPI.swift \
    tests/TimelyAPITests.swift -o "$TEST_DIR/timely-tests"
"$TEST_DIR/timely-tests"

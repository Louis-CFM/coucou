#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-devin-api.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/DevinAPI.swift \
    tests/DevinAPITests.swift -o "$TEST_DIR/devin-api-tests"
"$TEST_DIR/devin-api-tests"

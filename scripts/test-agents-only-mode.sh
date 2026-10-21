#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-focus-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    NotchBuddy/Sources/App/AgentsOnlyMode.swift tests/AgentsOnlyModeTests.swift \
    -o "$TEST_DIR/focus-tests"
"$TEST_DIR/focus-tests"

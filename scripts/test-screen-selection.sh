#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-screen.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/IslandScreenSelection.swift \
    tests/IslandScreenSelectionTests.swift -o "$TEST_DIR/screen-tests"
"$TEST_DIR/screen-tests"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-auto-close.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/IslandStateMachine.swift \
    tests/IslandAutoCloseTests.swift -o "$TEST_DIR/auto-close-tests"
"$TEST_DIR/auto-close-tests"

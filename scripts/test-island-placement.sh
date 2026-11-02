#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-island-placement.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/IslandPlacement.swift \
    tests/IslandPlacementTests.swift -o "$TEST_DIR/island-placement-tests"
"$TEST_DIR/island-placement-tests"

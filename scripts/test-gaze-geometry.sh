#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-gaze.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/IslandGazeGeometry.swift \
    tests/IslandGazeGeometryTests.swift -o "$TEST_DIR/gaze-tests"
"$TEST_DIR/gaze-tests"

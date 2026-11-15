#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-island-clock.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/IslandClock.swift tests/IslandClockTests.swift -o "$TEST_DIR/island-clock-tests"
"$TEST_DIR/island-clock-tests"

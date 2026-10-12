#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-stop-timers.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 NotchBuddy/Sources/App/StopTimerBook.swift \
    tests/StopTimerBookTests.swift -o "$TEST_DIR/stop-timer-tests"
"$TEST_DIR/stop-timer-tests"

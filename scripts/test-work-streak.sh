#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-work-streak.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/WorkStreak.swift tests/WorkStreakTests.swift -o "$TEST_DIR/work-streak-tests"
"$TEST_DIR/work-streak-tests"

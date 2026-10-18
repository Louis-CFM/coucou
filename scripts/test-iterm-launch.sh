#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-iterm-launch.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ItermLaunch.swift \
    tests/ItermLaunchTests.swift -o "$TEST_DIR/iterm-launch-tests"
"$TEST_DIR/iterm-launch-tests"

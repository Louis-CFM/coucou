#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-session-pills.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ClaudeSessionPills.swift \
    tests/ClaudeSessionPillsTests.swift -o "$TEST_DIR/session-pills-tests"
"$TEST_DIR/session-pills-tests"

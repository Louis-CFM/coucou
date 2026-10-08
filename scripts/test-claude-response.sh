#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-claude-response.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
    NotchBuddy/Sources/App/ClaudeResponseText.swift \
    tests/ClaudeResponseTextTests.swift -o "$TEST_DIR/claude-response-tests"
"$TEST_DIR/claude-response-tests"

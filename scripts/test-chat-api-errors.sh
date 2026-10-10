#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-errors.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 NotchBuddy/Sources/App/ChatAPIError.swift \
    tests/ChatAPIErrorTests.swift -o "$TEST_DIR/chat-api-errors"
"$TEST_DIR/chat-api-errors"

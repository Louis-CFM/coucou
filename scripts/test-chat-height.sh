#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-height.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/CoucouKit/ChatHeight.swift \
    tests/ChatHeightTests.swift -o "$TEST_DIR/chat-height-tests"
"$TEST_DIR/chat-height-tests"

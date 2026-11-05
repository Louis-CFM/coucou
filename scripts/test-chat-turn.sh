#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-turn.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ChatTurn.swift tests/ChatTurnTests.swift -o "$TEST_DIR/chat-turn-tests"
"$TEST_DIR/chat-turn-tests"
# Both builds compile the same file with no flag: it must type check with and without APPSTORE.
swiftc -swift-version 6 -typecheck NotchBuddy/Sources/App/ChatTurn.swift
swiftc -swift-version 6 -D APPSTORE -typecheck NotchBuddy/Sources/App/ChatTurn.swift
echo "ChatTurn type checks with and without APPSTORE."

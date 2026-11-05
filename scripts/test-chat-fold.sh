#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-fold.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ChatFoldMemory.swift tests/ChatFoldMemoryTests.swift -o "$TEST_DIR/chat-fold-tests"
"$TEST_DIR/chat-fold-tests"
# Both builds compile the same file with no flag: it must type check with and without APPSTORE.
swiftc -swift-version 6 -typecheck NotchBuddy/Sources/App/ChatFoldMemory.swift
swiftc -swift-version 6 -D APPSTORE -typecheck NotchBuddy/Sources/App/ChatFoldMemory.swift
echo "ChatFoldMemory type checks with and without APPSTORE."

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-claude-code-chat.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ClaudeCodeChat.swift \
    tests/ClaudeCodeChatTests.swift -o "$TEST_DIR/claude-code-chat-tests"
"$TEST_DIR/claude-code-chat-tests"

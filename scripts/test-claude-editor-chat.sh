#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-claude-editor-chat.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ClaudeEditorChat.swift \
    tests/ClaudeEditorChatTests.swift -o "$TEST_DIR/claude-editor-chat-tests"
"$TEST_DIR/claude-editor-chat-tests"

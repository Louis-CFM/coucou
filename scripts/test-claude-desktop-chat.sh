#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-claude-desktop.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ClaudeDesktopChat.swift tests/ClaudeDesktopChatTests.swift -o "$TEST_DIR/claude-desktop-tests"
"$TEST_DIR/claude-desktop-tests"

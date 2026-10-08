#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-openrouter.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 NotchBuddy/Sources/App/OpenRouterChat.swift \
    tests/OpenRouterChatTests.swift -o "$TEST_DIR/openrouter-tests"
"$TEST_DIR/openrouter-tests"

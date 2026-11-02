#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-claude-hook-removal.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/NbHookEntries.swift \
    tests/ClaudeHookRemovalTests.swift -o "$TEST_DIR/claude-hook-removal-tests"
"$TEST_DIR/claude-hook-removal-tests"

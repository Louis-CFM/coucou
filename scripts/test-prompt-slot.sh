#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-prompt-slot.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/PromptSlot.swift tests/PromptSlotTests.swift -o "$TEST_DIR/prompt-slot-tests"
"$TEST_DIR/prompt-slot-tests"
# The App Store build compiles the same file: it must type check with the flag defined.
swiftc -swift-version 6 -D APPSTORE -typecheck NotchBuddy/Sources/App/PromptSlot.swift
echo "PromptSlot type checks with APPSTORE."

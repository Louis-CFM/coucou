#!/usr/bin/env bash
# Real MultilineField, real window, real key events: keys, keypad Enter, composition, undo, drag types.
# Needs a window server (a logged in Mac). No network, no general pasteboard.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-multiline-field.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library -swift-version 5 \
    NotchBuddy/Sources/CoucouKit/ColorHex.swift \
    NotchBuddy/Sources/App/MultilineInput.swift \
    NotchBuddy/Sources/App/MultilineField.swift \
    tests/MultilineFieldTests.swift -o "$TEST_DIR/multiline-field-tests"
"$TEST_DIR/multiline-field-tests"

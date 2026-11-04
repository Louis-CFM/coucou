#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-dictation-order.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/Voice/VoiceLanguage.swift \
    tests/DictationOrderTests.swift -o "$TEST_DIR/dictation-order-tests"
"$TEST_DIR/dictation-order-tests"

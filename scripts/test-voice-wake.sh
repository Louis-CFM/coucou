#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-voice-wake.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc \
    NotchBuddy/Sources/App/Voice/WakePhrase.swift \
    tests/WakePhraseTests.swift -o "$TEST_DIR/wake-phrase-tests"
"$TEST_DIR/wake-phrase-tests"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-voice-language.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/Voice/VoiceLanguage.swift \
    tests/VoiceLanguageTests.swift -o "$TEST_DIR/voice-language-tests"
"$TEST_DIR/voice-language-tests"

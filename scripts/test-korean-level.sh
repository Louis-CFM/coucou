#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-korean-level.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/KoreanSpeechLevel.swift tests/KoreanSpeechLevelTests.swift -o "$TEST_DIR/korean-level-tests"
"$TEST_DIR/korean-level-tests"

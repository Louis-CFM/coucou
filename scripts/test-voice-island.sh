#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-voice-island.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/IslandStateMachine.swift \
    tests/VoiceIslandTests.swift -o "$TEST_DIR/voice-island-tests"
"$TEST_DIR/voice-island-tests"

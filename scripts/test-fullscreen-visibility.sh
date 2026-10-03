#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-fullscreen.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/FullscreenVisibility.swift \
    tests/FullscreenVisibilityTests.swift -o "$TEST_DIR/fullscreen-tests"
"$TEST_DIR/fullscreen-tests"

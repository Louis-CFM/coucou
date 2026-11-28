#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-memory-settings.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/MemorySettingsLogic.swift \
    tests/MemorySettingsTests.swift -o "$TEST_DIR/memory-settings-tests"
"$TEST_DIR/memory-settings-tests"

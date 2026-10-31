#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-settings-search.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/SettingsSearchMatch.swift \
    tests/SettingsSearchTests.swift -o "$TEST_DIR/settings-search-tests"
"$TEST_DIR/settings-search-tests"

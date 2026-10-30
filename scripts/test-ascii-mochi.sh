#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-ascii-mochi.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/AsciiMochi.swift tests/AsciiMochiTests.swift -o "$TEST_DIR/ascii-mochi-tests"
"$TEST_DIR/ascii-mochi-tests"

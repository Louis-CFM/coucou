#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-desktop.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/DesktopMochiLogic.swift \
    tests/DesktopMochiTests.swift -o "$TEST_DIR/desktop-mochi-tests"
"$TEST_DIR/desktop-mochi-tests"

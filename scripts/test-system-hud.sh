#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-system-hud.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/SystemControls/SystemHUDLogic.swift \
    tests/SystemHUDLogicTests.swift -o "$TEST_DIR/system-hud-tests"
"$TEST_DIR/system-hud-tests"

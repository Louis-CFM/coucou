#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-jetbrains-ide.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/JetBrainsIDE.swift \
    tests/JetBrainsIDETests.swift -o "$TEST_DIR/jetbrains-ide-tests"
"$TEST_DIR/jetbrains-ide-tests"

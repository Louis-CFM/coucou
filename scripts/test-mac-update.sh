#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-mac-update.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/MacUpdate.swift tests/MacUpdateTests.swift -o "$TEST_DIR/mac-update-tests"
"$TEST_DIR/mac-update-tests"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-terminal-target.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/TerminalTarget.swift \
    tests/TerminalTargetTests.swift -o "$TEST_DIR/terminal-target-tests"
"$TEST_DIR/terminal-target-tests"

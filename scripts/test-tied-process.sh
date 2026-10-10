#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-tied-process.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/TiedProcess.swift tests/TiedProcessTests.swift -o "$TEST_DIR/tied-process-tests"
"$TEST_DIR/tied-process-tests"

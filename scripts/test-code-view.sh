#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-code-view.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/CodeSession.swift tests/CodeSessionTests.swift -o "$TEST_DIR/code-view-tests"
"$TEST_DIR/code-view-tests"

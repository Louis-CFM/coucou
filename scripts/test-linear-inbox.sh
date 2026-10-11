#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-linear-inbox.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/LinearInbox.swift \
    tests/LinearInboxTests.swift -o "$TEST_DIR/linear-inbox-tests"
"$TEST_DIR/linear-inbox-tests"

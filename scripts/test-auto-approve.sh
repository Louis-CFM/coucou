#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-auto-approve.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/AutoApprove.swift \
    tests/AutoApproveTests.swift -o "$TEST_DIR/auto-approve-tests"
"$TEST_DIR/auto-approve-tests"

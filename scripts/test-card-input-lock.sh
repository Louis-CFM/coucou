#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-card-input-lock.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/CardInputLock.swift \
    tests/CardInputLockTests.swift -o "$TEST_DIR/card-input-lock-tests"
"$TEST_DIR/card-input-lock-tests"

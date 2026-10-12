#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hook-ack.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/HookAck.swift \
    tests/HookAckTests.swift -o "$TEST_DIR/hook-ack-tests"
"$TEST_DIR/hook-ack-tests"

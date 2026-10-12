#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-apns-retry.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/PhoneLink/ApnsRetry.swift \
    tests/ApnsRetryTests.swift -o "$TEST_DIR/apns-retry-tests"
"$TEST_DIR/apns-retry-tests"

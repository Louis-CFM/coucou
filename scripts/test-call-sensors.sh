#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-call-sensors.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/CallSensors.swift \
    tests/CallSensorsTests.swift -o "$TEST_DIR/call-sensors-tests"
"$TEST_DIR/call-sensors-tests"

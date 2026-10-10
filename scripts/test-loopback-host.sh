#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-loopback.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/LoopbackHost.swift tests/LoopbackHostTests.swift -o "$TEST_DIR/loopback-host-tests"
"$TEST_DIR/loopback-host-tests"

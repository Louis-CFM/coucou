#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hook-client.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/HookClient.swift \
    tests/HookClientTests.swift -o "$TEST_DIR/hook-client-tests"
"$TEST_DIR/hook-client-tests"

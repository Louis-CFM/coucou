#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-claude-endpoint.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ClaudeEndpoint.swift \
    tests/ClaudeEndpointTests.swift -o "$TEST_DIR/claude-endpoint-tests"
"$TEST_DIR/claude-endpoint-tests"

#!/usr/bin/env bash
# OpenCode Go chat routing and request/response helpers. No network, no Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-opencode-go.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/OpenCodeGo.swift \
    tests/OpenCodeGoRoutingTests.swift -o "$TEST_DIR/opencode-go-tests"
"$TEST_DIR/opencode-go-tests"

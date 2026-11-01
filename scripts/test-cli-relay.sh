#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-cli-relay.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/CLIRelay.swift tests/CLIRelayTests.swift -o "$TEST_DIR/cli-relay-tests"
"$TEST_DIR/cli-relay-tests"

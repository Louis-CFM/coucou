#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-n8n-poller.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/N8nExecution.swift \
    tests/N8nPollerTests.swift -o "$TEST_DIR/n8n-poller-tests"
"$TEST_DIR/n8n-poller-tests"

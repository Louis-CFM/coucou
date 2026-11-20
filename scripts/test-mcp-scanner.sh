#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-mcp-scanner.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/CoucouKit/MCPModels.swift \
    NotchBuddy/Sources/CoucouKit/MCPScanner.swift \
    tests/MCPScannerTests.swift -o "$TEST_DIR/mcp-scanner-tests"
"$TEST_DIR/mcp-scanner-tests"

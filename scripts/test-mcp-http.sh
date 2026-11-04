#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-mcp-http.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/CoucouKit/MCPModels.swift \
    NotchBuddy/Sources/CoucouKit/MCPJSONRPC.swift \
    NotchBuddy/Sources/CoucouKit/MCPScanner.swift \
    NotchBuddy/Sources/CoucouKit/MCPHTTPClient.swift \
    tests/MCPHTTPClientTests.swift -o "$TEST_DIR/mcp-http-tests"
"$TEST_DIR/mcp-http-tests"

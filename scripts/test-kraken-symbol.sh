#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-kraken-symbol.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/KrakenSymbol.swift \
    tests/KrakenSymbolTests.swift -o "$TEST_DIR/kraken-symbol-tests"
"$TEST_DIR/kraken-symbol-tests"

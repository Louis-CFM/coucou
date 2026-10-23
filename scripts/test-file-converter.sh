#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-file-converter.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 NotchBuddy/Sources/App/FileConverter.swift \
    tests/FileConverterTests.swift -o "$TEST_DIR/file-converter-tests"
"$TEST_DIR/file-converter-tests"

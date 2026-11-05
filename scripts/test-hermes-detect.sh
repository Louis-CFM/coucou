#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hermes-detect.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=(NotchBuddy/Sources/App/HermesDetect.swift)
swiftc -swift-version 6 -typecheck "${SOURCES[@]}"
swiftc -swift-version 6 -D APPSTORE -typecheck "${SOURCES[@]}"
swiftc "${SOURCES[@]}" tests/HermesDetectTests.swift -o "$TEST_DIR/hermes-detect-tests"
"$TEST_DIR/hermes-detect-tests"

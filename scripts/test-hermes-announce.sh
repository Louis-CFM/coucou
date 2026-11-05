#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hermes-announce.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/HermesAnnounce.swift \
    tests/HermesAnnounceTests.swift -o "$TEST_DIR/hermes-announce-tests"
"$TEST_DIR/hermes-announce-tests"

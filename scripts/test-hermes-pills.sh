#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hermes-pills.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/HermesPills.swift \
    tests/HermesPillsTests.swift -o "$TEST_DIR/hermes-pills-tests"
"$TEST_DIR/hermes-pills-tests"

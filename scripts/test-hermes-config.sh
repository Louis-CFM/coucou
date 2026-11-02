#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hermes-config.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/HermesConfigMerger.swift \
    tests/HermesConfigMergerTests.swift -o "$TEST_DIR/hermes-config-tests"
"$TEST_DIR/hermes-config-tests"

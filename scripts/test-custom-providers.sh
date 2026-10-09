#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-custom-providers.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/CoucouKit/CustomProviders.swift \
    NotchBuddy/Sources/CoucouKit/CLIChatTools.swift \
    tests/CustomProvidersTests.swift -o "$TEST_DIR/custom-providers-tests"
"$TEST_DIR/custom-providers-tests"

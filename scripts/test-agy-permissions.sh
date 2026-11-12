#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-agy-permissions.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/AgyPermissionRules.swift \
    tests/AgyPermissionRulesTests.swift -o "$TEST_DIR/agy-permissions-tests"
"$TEST_DIR/agy-permissions-tests"

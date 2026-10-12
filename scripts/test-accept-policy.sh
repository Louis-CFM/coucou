#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-accept-policy.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/AcceptPolicy.swift \
    tests/AcceptPolicyTests.swift -o "$TEST_DIR/accept-policy-tests"
"$TEST_DIR/accept-policy-tests"

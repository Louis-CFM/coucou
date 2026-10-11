#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-remote-trust.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/RemoteTrust.swift tests/RemoteTrustTests.swift -o "$TEST_DIR/remote-trust-tests"
"$TEST_DIR/remote-trust-tests"

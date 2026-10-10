#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-session-pill-id.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/SessionPillId.swift tests/SessionPillIdTests.swift -o "$TEST_DIR/session-pill-id-tests"
"$TEST_DIR/session-pill-id-tests"

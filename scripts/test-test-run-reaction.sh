#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-test-run-reaction.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/TestRunReaction.swift tests/TestRunReactionTests.swift -o "$TEST_DIR/test-run-reaction-tests"
"$TEST_DIR/test-run-reaction-tests"

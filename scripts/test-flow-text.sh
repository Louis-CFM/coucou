#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-flow-text.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/FlowText.swift tests/FlowTextTests.swift -o "$TEST_DIR/flow-text-tests"
"$TEST_DIR/flow-text-tests"

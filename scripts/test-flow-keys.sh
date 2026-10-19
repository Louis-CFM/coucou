#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-flow-keys.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/FlowKeyLogic.swift NotchBuddy/Sources/App/DictationTranscript.swift \
    tests/FlowKeyLogicTests.swift -o "$TEST_DIR/flow-keys-tests"
"$TEST_DIR/flow-keys-tests"

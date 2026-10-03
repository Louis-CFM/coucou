#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-idle.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/IdleMicroAnimation.swift \
    tests/IdleMicroAnimationTests.swift -o "$TEST_DIR/idle-tests"
"$TEST_DIR/idle-tests"

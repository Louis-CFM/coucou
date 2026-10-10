#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-live-reveal.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/CoucouKit/LiveReveal.swift tests/LiveRevealTests.swift -o "$TEST_DIR/live-reveal-tests"
"$TEST_DIR/live-reveal-tests"

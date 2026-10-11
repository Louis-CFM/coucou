#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-slack.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/SlackParsing.swift \
    tests/SlackParsingTests.swift -o "$TEST_DIR/slack-tests"
"$TEST_DIR/slack-tests"

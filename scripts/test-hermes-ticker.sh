#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hermes-ticker.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ChatTurn.swift NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/App/HermesTicker.swift NotchBuddy/Sources/App/ChatMediaDirectives.swift \
    NotchBuddy/Sources/App/ChatMarkdown.swift NotchBuddy/Sources/App/SafeWebURL.swift tests/HermesTickerTests.swift -o "$TEST_DIR/hermes-ticker-tests"
"$TEST_DIR/hermes-ticker-tests"

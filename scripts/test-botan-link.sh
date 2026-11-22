#!/usr/bin/env bash
# The Mac side of the Botan link (docs/BOTAN_LINK.md): what the screen shows for the island's picture,
# the line's fields, and the button's decisions against the request still pending. Pure file only:
# no Bluetooth, no AppState.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-botan-link.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/BotanLink/BotanLinkScreen.swift tests/BotanLinkTests.swift -o "$TEST_DIR/botan-link-tests"
"$TEST_DIR/botan-link-tests"

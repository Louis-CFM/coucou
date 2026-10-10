#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-open-webui.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/OpenWebUI.swift NotchBuddy/Sources/App/LocalChat.swift \
    tests/OpenWebUITests.swift -o "$TEST_DIR/open-webui-tests"
"$TEST_DIR/open-webui-tests"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-opencode-plugin.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/OpenCodePluginTemplate.swift \
    tests/OpenCodePluginTemplateTests.swift -o "$TEST_DIR/opencode-plugin-tests"
"$TEST_DIR/opencode-plugin-tests"

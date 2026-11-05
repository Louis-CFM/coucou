#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-demo-guard.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
APP=NotchBuddy/Sources/App
swiftc $APP/DemoGuard.swift tests/DemoGuardTests.swift -o "$TEST_DIR/demo-guard-tests"
"$TEST_DIR/demo-guard-tests"
# Both builds compile these files with no flag: they must type check with and without APPSTORE.
swiftc -swift-version 6 -typecheck $APP/DemoGuard.swift
swiftc -swift-version 6 -D APPSTORE -typecheck $APP/DemoGuard.swift
echo "DemoGuard type checks with and without APPSTORE."

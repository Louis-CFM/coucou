#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hermes-approval.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=(
    NotchBuddy/Sources/App/HermesApproval.swift
    NotchBuddy/Sources/App/HermesPills.swift
    NotchBuddy/Sources/App/CardInputLock.swift
)
# The center decides which request is on screen; it runs here against a fake card slot (no AppState, no HookServer).
CENTER=("${SOURCES[@]}" NotchBuddy/Sources/App/HermesApprovalCenter.swift)
# The app code must compile in Swift 6 mode (the app target does); the test binaries use the default mode,
# and the code must compile in the App Store configuration too.
swiftc -swift-version 6 -typecheck "${CENTER[@]}"
swiftc -swift-version 6 -D APPSTORE -typecheck "${CENTER[@]}"
swiftc "${SOURCES[@]}" tests/HermesApprovalTests.swift -o "$TEST_DIR/hermes-approval-tests"
"$TEST_DIR/hermes-approval-tests"
swiftc "${CENTER[@]}" tests/HermesApprovalCenterTests.swift -o "$TEST_DIR/hermes-approval-center-tests"
"$TEST_DIR/hermes-approval-center-tests"

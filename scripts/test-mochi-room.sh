#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-mochi-room.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/MochiRoom.swift NotchBuddy/Sources/App/GitHubPulse.swift \
    tests/MochiRoomTests.swift -o "$TEST_DIR/mochi-room-tests"
"$TEST_DIR/mochi-room-tests"

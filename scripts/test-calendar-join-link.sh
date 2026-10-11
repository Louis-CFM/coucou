#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-calendar-join-link.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/CalendarJoinLink.swift tests/CalendarJoinLinkTests.swift -o "$TEST_DIR/calendar-join-link-tests"
"$TEST_DIR/calendar-join-link-tests"

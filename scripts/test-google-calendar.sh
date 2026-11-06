#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-gcal.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/IntegrationNews.swift \
    NotchBuddy/Sources/App/GoogleCalendar.swift \
    tests/GoogleCalendarTests.swift -o "$TEST_DIR/google-calendar-tests"
"$TEST_DIR/google-calendar-tests"

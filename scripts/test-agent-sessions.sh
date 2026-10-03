#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-agent-sessions.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/AgentSessions.swift \
    tests/AgentSessionsTests.swift -o "$TEST_DIR/agent-sessions-tests"
"$TEST_DIR/agent-sessions-tests"

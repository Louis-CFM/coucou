#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-ssh-destination.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/SSHDestination.swift tests/SSHDestinationTests.swift -o "$TEST_DIR/ssh-destination-tests"
"$TEST_DIR/ssh-destination-tests"

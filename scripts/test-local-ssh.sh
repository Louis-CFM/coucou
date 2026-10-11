#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-local-ssh.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/LocalSSH.swift tests/LocalSSHTests.swift -o "$TEST_DIR/local-ssh-tests"
"$TEST_DIR/local-ssh-tests"

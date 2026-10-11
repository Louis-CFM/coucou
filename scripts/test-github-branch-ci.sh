#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-github-branch-ci.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/GitHubPulse.swift \
    NotchBuddy/Sources/App/GitHubBranchCI.swift \
    tests/GitHubBranchCITests.swift -o "$TEST_DIR/github-branch-ci-tests"
"$TEST_DIR/github-branch-ci-tests"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-github-prs.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/GithubPullRequests.swift \
    tests/GithubPullRequestsTests.swift -o "$TEST_DIR/github-prs-tests"
"$TEST_DIR/github-prs-tests"

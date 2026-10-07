#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-git-repo-info.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/GitRepoInfo.swift \
    tests/GitRepoInfoTests.swift -o "$TEST_DIR/git-repo-info-tests"
"$TEST_DIR/git-repo-info-tests"

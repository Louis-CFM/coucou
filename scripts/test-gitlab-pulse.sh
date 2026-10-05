#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-gitlab-pulse.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/GitHubPulse.swift NotchBuddy/Sources/App/GitLabPulse.swift \
    tests/GitLabPulseTests.swift -o "$TEST_DIR/gitlab-pulse-tests"
"$TEST_DIR/gitlab-pulse-tests"

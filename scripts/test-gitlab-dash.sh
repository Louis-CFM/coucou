#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-gitlab-dash.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/GitHubPulse.swift \
    NotchBuddy/Sources/App/GitHubActivity.swift \
    NotchBuddy/Sources/App/GitLabPulse.swift \
    NotchBuddy/Sources/App/GitLabDash.swift \
    tests/GitLabDashTests.swift -o "$TEST_DIR/gitlab-dash-tests"
"$TEST_DIR/gitlab-dash-tests"

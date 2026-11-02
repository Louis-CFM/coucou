#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-mail-triage.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/MailTriage.swift NotchBuddy/Sources/App/MailPlan.swift \
    tests/MailTriageTests.swift tests/MailPlanTests.swift -o "$TEST_DIR/mail-triage-tests"
"$TEST_DIR/mail-triage-tests"

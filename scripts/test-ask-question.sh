#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-ask-question.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/AskQuestion.swift \
    tests/AskQuestionTests.swift -o "$TEST_DIR/ask-question-tests"
"$TEST_DIR/ask-question-tests"

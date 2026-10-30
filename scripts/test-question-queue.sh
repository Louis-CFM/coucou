#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-question-queue.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/QuestionQueue.swift NotchBuddy/Sources/App/AskQuestion.swift \
    tests/QuestionQueueTests.swift -o "$TEST_DIR/question-queue-tests"
"$TEST_DIR/question-queue-tests"

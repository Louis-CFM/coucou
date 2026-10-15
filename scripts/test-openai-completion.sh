#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-openai-completion.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/OpenAICompletion.swift NotchBuddy/Sources/App/LocalChat.swift \
    tests/OpenAICompletionTests.swift -o "$TEST_DIR/openai-completion-tests"
"$TEST_DIR/openai-completion-tests"

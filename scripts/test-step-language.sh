#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-step-language.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/StepLanguage.swift NotchBuddy/Sources/App/AppLanguage.swift \
    tests/StepLanguageTests.swift -o "$TEST_DIR/step-language-tests"
"$TEST_DIR/step-language-tests"

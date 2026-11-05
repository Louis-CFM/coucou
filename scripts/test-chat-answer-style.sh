#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-answer-style.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
APP=NotchBuddy/Sources/App
swiftc -O $APP/ChatTurn.swift $APP/ChatMarkdown.swift $APP/ChatAnswerStyle.swift $APP/ChatMediaDirectives.swift $APP/SafeWebURL.swift tests/ChatAnswerStyleTests.swift -o "$TEST_DIR/chat-answer-style-tests"
"$TEST_DIR/chat-answer-style-tests"
# Both builds compile these files with no flag: they must type check with and without APPSTORE.
swiftc -swift-version 6 -typecheck $APP/ChatTurn.swift $APP/ChatMarkdown.swift $APP/ChatAnswerStyle.swift $APP/ChatMediaDirectives.swift $APP/SafeWebURL.swift
swiftc -swift-version 6 -D APPSTORE -typecheck $APP/ChatTurn.swift $APP/ChatMarkdown.swift $APP/ChatAnswerStyle.swift $APP/ChatMediaDirectives.swift $APP/SafeWebURL.swift
echo "ChatAnswerStyle type checks with and without APPSTORE."

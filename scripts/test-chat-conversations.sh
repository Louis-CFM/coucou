#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-conversations.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ChatConversations.swift \
    NotchBuddy/Sources/App/ChatTurn.swift \
    NotchBuddy/Sources/App/HermesApproval.swift \
    NotchBuddy/Sources/App/HermesChat.swift \
    NotchBuddy/Sources/App/HermesAnnounce.swift \
    NotchBuddy/Sources/App/HermesPills.swift \
    NotchBuddy/Sources/App/LocalChat.swift \
    NotchBuddy/Sources/App/SafeWebURL.swift \
    tests/ChatConversationsTests.swift -o "$TEST_DIR/chat-conversations-tests"
"$TEST_DIR/chat-conversations-tests"

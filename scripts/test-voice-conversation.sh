#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/voice-conversation-tests
echo "=== Voice conversation end-phrase tests ==="
swiftc -swift-version 6 -strict-concurrency=complete \
    "$ROOT/NotchBuddy/Sources/App/Voice/TurnEndPolicy.swift" \
    "$ROOT/tests/VoiceConversationTests.swift" \
    -o "$OUT"
"$OUT"

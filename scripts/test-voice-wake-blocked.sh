#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/wake-blocked-tests
echo "=== VoiceWakeFilter tests ==="
swiftc -swift-version 6 -strict-concurrency=complete \
    "$ROOT/tests/IslandTypeStubs.swift" \
    "$ROOT/NotchBuddy/Sources/App/Voice/VoiceWakeFilter.swift" \
    "$ROOT/tests/WakeBlockedTests.swift" \
    -o "$OUT"
"$OUT"

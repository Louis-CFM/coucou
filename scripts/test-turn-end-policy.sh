#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/turn-end-policy-tests
echo "=== TurnEndPolicy tests ==="
swiftc -swift-version 6 -strict-concurrency=complete \
    "$ROOT/tests/IslandTypeStubs.swift" \
    "$ROOT/NotchBuddy/Sources/App/Voice/TurnEndPolicy.swift" \
    "$ROOT/tests/TurnEndPolicyTests.swift" \
    -o "$OUT"
"$OUT"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/spotter-gen-tests

echo "=== SpotterGeneration tests ==="
swiftc -o "$OUT" \
    "$ROOT/NotchBuddy/Sources/App/Voice/SpotterGeneration.swift" \
    "$ROOT/tests/SpotterGenerationTests.swift"
"$OUT"

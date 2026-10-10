#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/live-edits-tests
echo "=== LiveEdits tests ==="
swiftc -swift-version 6 -strict-concurrency=complete \
    "$ROOT/NotchBuddy/Sources/CoucouKit/LiveEdits.swift" \
    "$ROOT/tests/LiveEditsTests.swift" \
    -o "$OUT"
"$OUT"

#!/bin/bash
# Native main-session attention: Python readers + watcher, and the Swift queue/model.
# No network, no dependencies: /usr/bin/python3 (3.9) and the system Swift compiler.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Python reader tests (Codex transcripts, permissions, OpenCode) =="
/usr/bin/python3 tests/test_attention_bridge.py

echo "== Python watcher tests (kqueue vnode sources, coalescing, stdin) =="
/usr/bin/python3 tests/test_attention_watch.py

echo "== Swift attention queue/model tests =="
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
# -DDEBUG matches the app's Debug configuration (the isolated smoke-test path
# only exists there).
xcrun swiftc -parse-as-library -DDEBUG \
  -o "$BUILD_DIR/main_session_attention_tests" \
  tests/MainSessionAttentionTests.swift \
  NotchBuddy/Sources/App/MainSessionAttention.swift
"$BUILD_DIR/main_session_attention_tests"

echo "All main-session attention tests passed."

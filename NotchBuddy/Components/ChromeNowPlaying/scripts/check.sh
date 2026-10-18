#!/bin/bash
set -euo pipefail
BRIDGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-media-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
/bin/bash "$BRIDGE_ROOT/scripts/build-bridge.sh" "$CHECK_DIR"
xcrun swiftc -swift-version 6 -module-cache-path "$CHECK_DIR/module-cache" \
  "$BRIDGE_ROOT/Sources/BridgeProtocol.swift" "$BRIDGE_ROOT/Tests/ProtocolTests.swift" \
  -o "$CHECK_DIR/protocol-tests"
"$CHECK_DIR/protocol-tests"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
  -framework AppKit -framework Foundation "$BRIDGE_ROOT/Tests/NativeCapabilityTests.m" \
  -o "$CHECK_DIR/capability-tests"
"$CHECK_DIR/capability-tests"
python3 "$BRIDGE_ROOT/Tests/HelperSmoke.py" "$CHECK_DIR/NowPlayingBridge.dylib"

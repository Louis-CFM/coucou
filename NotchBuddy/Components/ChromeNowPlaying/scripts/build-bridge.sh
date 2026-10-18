#!/bin/bash
set -euo pipefail
BRIDGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_OUTPUT="${1:-$BRIDGE_ROOT/build}"
mkdir -p "$BRIDGE_OUTPUT"
BRIDGE_ARCH_FLAGS=(-arch "$(uname -m)")
if [[ -n "${ARCHS:-}" ]]; then
  BRIDGE_ARCH_FLAGS=()
  for BRIDGE_ARCH in $ARCHS; do
    case "$BRIDGE_ARCH" in
      arm64|x86_64) BRIDGE_ARCH_FLAGS+=(-arch "$BRIDGE_ARCH") ;;
      *) echo "Unsupported bridge architecture: $BRIDGE_ARCH" >&2; exit 1 ;;
    esac
  done
fi
xcrun --sdk macosx clang -dynamiclib -fobjc-arc -O2 -Wall -Wextra \
  -Wno-unused-parameter -mmacosx-version-min=15.0 "${BRIDGE_ARCH_FLAGS[@]}" \
  -install_name @rpath/NowPlayingBridge.dylib -framework AppKit -framework Foundation \
  "$BRIDGE_ROOT/Native/NowPlayingBridge.m" -o "$BRIDGE_OUTPUT/NowPlayingBridge.dylib"
BRIDGE_SIGNER="${EXPANDED_CODE_SIGN_IDENTITY:--}"
BRIDGE_SIGN_FLAGS=(--force --sign "$BRIDGE_SIGNER")
if [[ "$BRIDGE_SIGNER" != "-" ]]; then BRIDGE_SIGN_FLAGS+=(--options runtime --timestamp); fi
/usr/bin/codesign "${BRIDGE_SIGN_FLAGS[@]}" "$BRIDGE_OUTPUT/NowPlayingBridge.dylib"

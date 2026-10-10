#!/usr/bin/env bash
# Energy VAD tests — pure struct, no AVFoundation dependency.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-voice-vad.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc \
    NotchBuddy/Sources/App/Voice/EnergyVAD.swift \
    tests/EnergyVADTests.swift \
    -o "$TEST_DIR/energy-vad-tests"
"$TEST_DIR/energy-vad-tests"

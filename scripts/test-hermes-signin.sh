#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hermes-signin.XXXXXX")"
SERVER_PID=""
trap 'rm -rf "$TEST_DIR"; [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

PORT_FILE="$TEST_DIR/port.txt"
SOURCES=(
    NotchBuddy/Sources/App/ChatTurn.swift
    NotchBuddy/Sources/App/HermesApproval.swift
    NotchBuddy/Sources/App/HermesChat.swift
    NotchBuddy/Sources/App/HermesPills.swift
    NotchBuddy/Sources/App/HermesSignIn.swift
    NotchBuddy/Sources/App/HermesSignInNet.swift
    NotchBuddy/Sources/App/LocalChat.swift
    NotchBuddy/Sources/App/SafeWebURL.swift
)

# ── Start the fake dashboard (127.0.0.1 only; nothing here talks to a real server) ──
python3 tests/fake_hermes_dashboard.py "$PORT_FILE" &
SERVER_PID=$!

# ── The app code must compile in Swift 6 mode (the app target does); the test binary uses the default mode ──
swiftc -swift-version 6 -typecheck "${SOURCES[@]}"
# ... and without the code the App Store build leaves out (the listener and the browser flow)
swiftc -swift-version 6 -D APPSTORE -typecheck "${SOURCES[@]}"
swiftc "${SOURCES[@]}" tests/StallingListener.swift tests/HermesSignInApprovalTests.swift tests/HermesSignInTests.swift -o "$TEST_DIR/hermes-signin-tests"

for i in $(seq 1 300); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: fake Hermes dashboard process exited unexpectedly" >&2
        exit 1
    fi
    [ -s "$PORT_FILE" ] && break
    sleep 0.1
done

if [ ! -s "$PORT_FILE" ]; then
    echo "ERROR: fake Hermes dashboard did not write its port within 30 s" >&2
    exit 1
fi

PORT=$(cat "$PORT_FILE")
echo "Fake Hermes dashboard listening on port $PORT (PID $SERVER_PID)"

"$TEST_DIR/hermes-signin-tests" "$PORT"

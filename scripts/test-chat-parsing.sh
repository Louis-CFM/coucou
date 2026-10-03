#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-parsing.XXXXXX")"
SERVER_PID=""
trap 'rm -rf "$TEST_DIR"; [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

PORT_FILE="$TEST_DIR/port.txt"

# ── Start fake LLM server ────────────────────────────────────────────────────
python3 tests/fake_local_llm.py "$PORT_FILE" &
SERVER_PID=$!

# ── Compile test binary (runs in parallel with server startup) ───────────────
# Compilation typically takes a few seconds, which gives the server plenty of
# time to bind and write its port — avoiding a busy-wait on fast machines.
swiftc \
    NotchBuddy/Sources/App/LocalChat.swift \
    NotchBuddy/Sources/App/ChatMarkdown.swift \
    NotchBuddy/Sources/App/TokenUsage.swift \
    tests/ChatParsingTests.swift \
    -o "$TEST_DIR/chat-parsing-tests"

# ── Wait for server port file (up to 30 s) ───────────────────────────────────
for i in $(seq 1 300); do
    # Bail out immediately if the server process has already died
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: fake LLM server process exited unexpectedly" >&2
        exit 1
    fi
    [ -s "$PORT_FILE" ] && break
    sleep 0.1
done

if [ ! -s "$PORT_FILE" ]; then
    echo "ERROR: fake LLM server did not write its port within 30 s" >&2
    exit 1
fi

PORT=$(cat "$PORT_FILE")
echo "Fake LLM server listening on port $PORT (PID $SERVER_PID)"

# ── Run tests ────────────────────────────────────────────────────────────────
"$TEST_DIR/chat-parsing-tests" "$PORT"

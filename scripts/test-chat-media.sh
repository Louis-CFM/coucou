#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-media.XXXXXX")"
SERVER_PID=""
trap 'rm -rf "$TEST_DIR"; [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT
APP=NotchBuddy/Sources/App

# ── The pure parts: directives and the byte sniff ────────────────────────────
swiftc -O $APP/ChatMarkdown.swift $APP/SafeWebURL.swift $APP/ChatMediaDirectives.swift \
    tests/ChatMediaDirectivesTests.swift -o "$TEST_DIR/chat-media-directives-tests"
"$TEST_DIR/chat-media-directives-tests"
swiftc -O $APP/ChatMarkdown.swift $APP/SafeWebURL.swift $APP/ChatMediaDirectives.swift $APP/ChatMediaSniff.swift \
    tests/ChatMediaSniffTests.swift -o "$TEST_DIR/chat-media-sniff-tests"
"$TEST_DIR/chat-media-sniff-tests"

# The one Objective-C file (CoucouTry) catches the exceptions AVAudioEngine raises; the player needs it, so the tests
# build it the way the app targets do (bridging header) and link it.
CTRY="$TEST_DIR/CoucouTry.o"
clang -fobjc-arc -Wall -Werror -c $APP/CoucouTry.m -o "$CTRY"
BRIDGE=(-import-objc-header $APP/Coucou-Bridging-Header.h)

# ── The audio player: Ogg Opus voice notes open and play (AVAudioPlayer cannot play them; AVAudioFile can) ──
swiftc -swift-version 6 "${BRIDGE[@]}" $APP/ChatMediaPlayer.swift tests/ChatMediaPlayerTests.swift "$CTRY" -o "$TEST_DIR/chat-media-player-tests"
swiftc -swift-version 6 -D APPSTORE "${BRIDGE[@]}" -typecheck $APP/ChatMediaPlayer.swift
"$TEST_DIR/chat-media-player-tests"

# ── The fetch, against the fake dashboard (127.0.0.1 only; nothing here talks to a real server) ──
FETCH=(
    $APP/ChatTurn.swift $APP/HermesApproval.swift $APP/HermesChat.swift $APP/HermesPills.swift $APP/HermesSignIn.swift
    $APP/HermesSignInNet.swift $APP/LocalChat.swift
    $APP/SafeWebURL.swift $APP/ChatMarkdown.swift $APP/ChatMediaDirectives.swift $APP/ChatMediaSniff.swift
    $APP/ChatMediaFiles.swift $APP/ChatMediaFetch.swift
)
# Both builds compile these files: they must type check in Swift 6 mode with and without APPSTORE.
swiftc -swift-version 6 -typecheck "${FETCH[@]}"
swiftc -swift-version 6 -D APPSTORE -typecheck "${FETCH[@]}"
echo "Chat media files type check with and without APPSTORE."

# The store of the rows (queue, budget, cancellation, one player at a time, saved names) adds the player, the store and
# the conversation ids. The test supplies `ChatMediaStore.shared` (the app makes its own next to `HermesSessions.shared`).
STORE=("${FETCH[@]}" $APP/ChatConversations.swift $APP/ChatMediaPlayer.swift $APP/ChatMediaStore.swift)
swiftc -swift-version 6 "${BRIDGE[@]}" -typecheck "${STORE[@]}" tests/ChatMediaStoreTests.swift
# The App Store build has no sign in flow (the test needs it): its files are checked with a one line stand in for `shared`.
cat > "$TEST_DIR/SharedStub.swift" <<'EOF'
extension ChatMediaStore { static let shared = ChatMediaStore(sessions: HermesSessions(storage: HermesSessionStorage(load: { "" }, save: { _ in }))) }
EOF
swiftc -swift-version 6 -D APPSTORE "${BRIDGE[@]}" -typecheck "${STORE[@]}" "$TEST_DIR/SharedStub.swift"
echo "Chat media store type checks with and without APPSTORE."

PORT_FILE="$TEST_DIR/port.txt"
python3 tests/fake_hermes_dashboard.py "$PORT_FILE" &
SERVER_PID=$!
swiftc "${FETCH[@]}" tests/StallingListener.swift tests/ChatMediaFetchTests.swift -o "$TEST_DIR/chat-media-fetch-tests"
swiftc "${BRIDGE[@]}" "${STORE[@]}" tests/ChatMediaStoreTests.swift "$CTRY" -o "$TEST_DIR/chat-media-store-tests"
for i in $(seq 1 300); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: fake Hermes dashboard process exited unexpectedly" >&2
        exit 1
    fi
    [ -s "$PORT_FILE" ] && break
    sleep 0.1
done
[ -s "$PORT_FILE" ] || { echo "ERROR: fake Hermes dashboard did not write its port within 30 s" >&2; exit 1; }
"$TEST_DIR/chat-media-fetch-tests" "$(cat "$PORT_FILE")"
"$TEST_DIR/chat-media-store-tests" "$(cat "$PORT_FILE")"

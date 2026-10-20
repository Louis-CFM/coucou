#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-yandex-music.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/YandexMusicNowPlaying.swift \
    tests/YandexMusicNowPlayingTests.swift -o "$TEST_DIR/yandex-music-tests"
"$TEST_DIR/yandex-music-tests"

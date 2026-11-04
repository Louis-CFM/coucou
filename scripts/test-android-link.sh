#!/usr/bin/env bash
# The Mac side of the Android link (docs/ANDROID_LINK.md) against the vectors of the Windows/Linux
# server and the Android client: pairing link, fingerprints, TXT record, framing, admission, the hub's
# approval and question rules, the certificate. Pure files only: no socket, no Keychain, no AppState.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-android-link.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
LINK=NotchBuddy/Sources/App/AndroidLink
swiftc -swift-version 6 -strict-concurrency=complete \
    $LINK/AndroidLinkProtocol.swift $LINK/AndroidLinkAdmission.swift $LINK/AndroidLinkHub.swift \
    $LINK/AndroidLinkIdentity.swift tests/AndroidLinkTests.swift -o "$TEST_DIR/android-link-tests"
"$TEST_DIR/android-link-tests"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-cmux-timeline.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
APP=NotchBuddy/Sources/App
swiftc -O $APP/ChatTurn.swift $APP/CmuxTimeline.swift $APP/ChatMarkdown.swift $APP/ChatAnswerStyle.swift $APP/ChatMediaDirectives.swift $APP/SafeWebURL.swift tests/CmuxTimelineTests.swift -o "$TEST_DIR/cmux-timeline-tests"
"$TEST_DIR/cmux-timeline-tests"
# The shared files compile in both builds with no flag: they must type check with and without APPSTORE.
swiftc -swift-version 6 -typecheck $APP/ChatTurn.swift $APP/ChatMarkdown.swift $APP/ChatAnswerStyle.swift $APP/ChatMediaDirectives.swift $APP/SafeWebURL.swift
swiftc -swift-version 6 -D APPSTORE -typecheck $APP/ChatTurn.swift $APP/ChatMarkdown.swift $APP/ChatAnswerStyle.swift $APP/ChatMediaDirectives.swift $APP/SafeWebURL.swift
# The timeline itself is only in the cmux build, and Swift 6 must accept it.
swiftc -swift-version 6 -typecheck $APP/ChatTurn.swift $APP/CmuxTimeline.swift
# The App Store build has none of it: the file is empty there.
swiftc -swift-version 6 -D APPSTORE -typecheck $APP/ChatTurn.swift $APP/CmuxTimeline.swift
# Memory only, never sent to the phone: no Codable in the timeline, and nothing under the phone link names it.
if grep -n "Codable\|Encodable\|Decodable\|UserDefaults\|FileManager\|nbLog\|appendAppLog" $APP/CmuxTimeline.swift; then
    echo "CmuxTimeline.swift must not encode, persist or log."; exit 1
fi
if grep -rnE "CmuxTimeline|TimelineStore|TimelineTurn|TimelineEvent|TimelineNames" $APP/PhoneLink NotchBuddy/Sources/Phone NotchBuddy/Sources/CoucouKit 2>/dev/null; then
    echo "The phone link and the iPhone app must not name the cmux timeline."; exit 1
fi
echo "CmuxTimeline type checks with and without APPSTORE and stays in memory."

#!/usr/bin/env bash
set -e
echo "Running IntentParser tests…"
swiftc -o /tmp/voice-intent-tests \
  tests/VoiceTestStubs.swift \
  tests/PillFixture.swift \
  NotchBuddy/Sources/App/Voice/VoiceIntent.swift \
  NotchBuddy/Sources/App/Voice/EntityResolver.swift \
  NotchBuddy/Sources/App/Voice/IntentParser.swift \
  tests/IntentParserTests.swift
/tmp/voice-intent-tests

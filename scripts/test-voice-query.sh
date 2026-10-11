#!/usr/bin/env bash
set -e
echo "Running VoiceQuery tests…"
swiftc -o /tmp/voice-query-tests \
  tests/VoiceTestStubs.swift \
  tests/PillFixture.swift \
  NotchBuddy/Sources/App/Voice/VoiceIntent.swift \
  NotchBuddy/Sources/App/Voice/EntityResolver.swift \
  NotchBuddy/Sources/App/Voice/IntentParser.swift \
  NotchBuddy/Sources/App/Voice/VoiceQuery.swift \
  tests/VoiceQueryTests.swift
/tmp/voice-query-tests

#!/usr/bin/env bash
set -e
echo "Running VoiceActionRunner tests…"
swiftc -o /tmp/voice-runner-tests \
  tests/VoiceTestStubs.swift \
  tests/PillFixture.swift \
  NotchBuddy/Sources/App/Voice/VoiceIntent.swift \
  NotchBuddy/Sources/App/Voice/IntentParser.swift \
  NotchBuddy/Sources/App/Voice/VoiceQuery.swift \
  NotchBuddy/Sources/App/Voice/EntityResolver.swift \
  NotchBuddy/Sources/App/Voice/VoiceActionRunner.swift \
  tests/VoiceActionRunnerTests.swift
/tmp/voice-runner-tests

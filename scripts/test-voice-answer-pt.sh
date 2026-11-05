#!/usr/bin/env bash
set -e
echo "Running VoiceAnswer pt-BR tests…"
swiftc -o /tmp/voice-answer-pt-tests \
  tests/VoiceTestStubs.swift \
  tests/PillFixture.swift \
  NotchBuddy/Sources/App/Voice/VoiceLanguage.swift \
  NotchBuddy/Sources/App/Voice/VoicePortuguese.swift \
  NotchBuddy/Sources/App/Voice/VoiceAnswerPT.swift \
  NotchBuddy/Sources/App/Voice/VoiceIntent.swift \
  NotchBuddy/Sources/App/Voice/EntityResolver.swift \
  NotchBuddy/Sources/App/Voice/IntentParser.swift \
  NotchBuddy/Sources/App/Voice/VoiceQuery.swift \
  tests/VoiceAnswerPTTests.swift
/tmp/voice-answer-pt-tests

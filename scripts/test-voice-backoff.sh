#!/usr/bin/env bash
set -e
echo "Running WakeWindowBackoff tests…"
swiftc -o /tmp/voice-backoff-tests \
  NotchBuddy/Sources/App/Voice/WakeWindowBackoff.swift \
  tests/WakeWindowBackoffTests.swift
/tmp/voice-backoff-tests

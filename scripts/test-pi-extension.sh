#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift NotchBuddy/Tests/PiExtensionTests.swift

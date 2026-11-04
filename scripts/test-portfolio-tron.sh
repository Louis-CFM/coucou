#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-portfolio-tron.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/TronAccount.swift tests/PortfolioTronTests.swift -o "$TEST_DIR/portfolio-tron-tests"
"$TEST_DIR/portfolio-tron-tests"

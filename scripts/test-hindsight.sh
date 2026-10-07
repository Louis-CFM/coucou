#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hindsight.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
node scripts/test-hindsight-project.mjs
swiftc NotchBuddy/Sources/App/HindsightTypes.swift \
    NotchBuddy/Sources/App/KeychainStore.swift \
    NotchBuddy/Sources/App/HindsightService.swift \
    NotchBuddy/Sources/App/HindsightUIContracts.swift \
    tests/HindsightContractTests.swift -o "$TEST_DIR/hindsight-contract-tests"
"$TEST_DIR/hindsight-contract-tests"
swiftc NotchBuddy/Sources/App/HindsightTypes.swift \
    NotchBuddy/Sources/App/KeychainStore.swift \
    NotchBuddy/Sources/App/HindsightService.swift \
    NotchBuddy/Sources/App/HindsightUIContracts.swift \
    NotchBuddy/Sources/App/ChatMemoryContracts.swift \
    NotchBuddy/Sources/App/ChatMemoryCoordinator.swift \
    tests/ChatMemoryPolicyTests.swift -o "$TEST_DIR/chat-memory-policy-tests"
"$TEST_DIR/chat-memory-policy-tests"
swiftc NotchBuddy/Sources/App/HindsightTypes.swift \
    NotchBuddy/Sources/App/MemoryExport.swift \
    tests/MemoryExportTests.swift -o "$TEST_DIR/memory-export-tests"
"$TEST_DIR/memory-export-tests"

if [[ -n "${COUCOU_HINDSIGHT_TEST_URL:-}" || -n "${COUCOU_HINDSIGHT_TEST_TOKEN:-}" || -n "${COUCOU_HINDSIGHT_TEST_BANK:-}" ]]; then
    : "${COUCOU_HINDSIGHT_TEST_URL:?all three Hindsight live-test variables are required}"
    : "${COUCOU_HINDSIGHT_TEST_TOKEN:?all three Hindsight live-test variables are required}"
    : "${COUCOU_HINDSIGHT_TEST_BANK:?all three Hindsight live-test variables are required}"
    if [[ "${COUCOU_HINDSIGHT_TEST_BANK,,}" == "hieu" ]]; then
        echo "Refusing live Hindsight mutation tests against bank hieu" >&2
        exit 2
    fi
    echo "Running guarded disposable-bank Hindsight lifecycle"
    (cd windows && cargo test -p coucou hindsight::tests::live_disposable_bank_reversible_lifecycle -- --ignored --exact --nocapture)
else
    echo "Live Hindsight lifecycle skipped (no opt-in variables)."
fi

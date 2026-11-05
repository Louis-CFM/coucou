#!/usr/bin/env swift
// KrakenSymbolTests.swift — standalone regression tests for Kraken asset symbol mapping (#863).
// Run from repo root:
//   swift NotchBuddy/Tests/KrakenSymbolTests.swift

import Foundation

// ── Copy of krakenSymbol from PortfolioController.swift ───────────────────────
// Keep in sync with PortfolioController.swift krakenSymbol(_:).
func krakenSymbol(_ raw: String) -> String {
    let map: [String: String] = [
        "XXBT": "BTC", "XXDG": "DOGE", "XETH": "ETH", "XLTC": "LTC", "XXLM": "XLM",
        "XXMR": "XMR", "XXRP": "XRP", "XZEC": "ZEC", "ZUSD": "USD",
        "ZEUR": "EUR",  "ZGBP": "GBP", "ZCAD": "CAD", "ZJPY": "JPY",
    ]
    return map[raw] ?? (raw.count == 4 && (raw.hasPrefix("X") || raw.hasPrefix("Z")) ? String(raw.dropFirst()) : raw)
}

// ── Test runner ───────────────────────────────────────────────────────────────

var passed = 0
var failed = 0

func check(_ label: String, input: String, expected: String) {
    let got = krakenSymbol(input)
    if got == expected {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ \(label): expected '\(expected)', got '\(got)'")
    }
}

print("Running KrakenSymbolTests...")

// 1. Mapped 4-letter legacy crypto and fiat
check("XXBT -> BTC", input: "XXBT", expected: "BTC")
check("XXDG -> DOGE", input: "XXDG", expected: "DOGE")
check("XETH -> ETH", input: "XETH", expected: "ETH")
check("XLTC -> LTC", input: "XLTC", expected: "LTC")
check("XXLM -> XLM", input: "XXLM", expected: "XLM")
check("XXMR -> XMR", input: "XXMR", expected: "XMR")
check("XXRP -> XRP", input: "XXRP", expected: "XRP")
check("XZEC -> ZEC", input: "XZEC", expected: "ZEC")
check("ZUSD -> USD", input: "ZUSD", expected: "USD")
check("ZEUR -> EUR", input: "ZEUR", expected: "EUR")
check("ZGBP -> GBP", input: "ZGBP", expected: "GBP")
check("ZCAD -> CAD", input: "ZCAD", expected: "CAD")
check("ZJPY -> JPY", input: "ZJPY", expected: "JPY")

// 2. Unmapped 4-letter legacy codes with X or Z prefix
check("XREP (legacy Augur) -> REP", input: "XREP", expected: "REP")
check("XMLN (legacy Melon) -> MLN", input: "XMLN", expected: "MLN")

// 3. 3-letter tokens starting with X or Z must NOT be stripped (Issue #863)
check("XTZ (Tezos) stays XTZ", input: "XTZ", expected: "XTZ")
check("ZRX (0x Protocol) stays ZRX", input: "ZRX", expected: "ZRX")

// 4. Standard tokens without X/Z prefix
check("SOL stays SOL", input: "SOL", expected: "SOL")
check("DOT stays DOT", input: "DOT", expected: "DOT")
check("USDT stays USDT", input: "USDT", expected: "USDT")
check("ADA stays ADA", input: "ADA", expected: "ADA")

// 5. Boundary & edge cases
check("Empty string stays empty", input: "", expected: "")
check("Single X stays X", input: "X", expected: "X")
check("Single Z stays Z", input: "Z", expected: "Z")
check("XX stays XX", input: "XX", expected: "XX")
check("ZZ stays ZZ", input: "ZZ", expected: "ZZ")
check("XXXXX (5 chars) stays XXXXX", input: "XXXXX", expected: "XXXXX")

print("")
print("Results: \(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)

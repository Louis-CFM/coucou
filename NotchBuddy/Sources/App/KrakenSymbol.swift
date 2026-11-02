import Foundation

/// Kraken's asset name → the usual ticker: XXBT = BTC, XETH = ETH, ZUSD = USD, etc.
/// Only 4-letter legacy codes lose their X/Z prefix, so XTZ and ZRX stay as they are.
///
/// Kept free of network access so it can be tested on its own (scripts/test-kraken-symbol.sh).
func krakenSymbol(_ raw: String) -> String {
    let map: [String: String] = [
        "XXBT": "BTC", "XXDG": "DOGE", "XETH": "ETH", "XLTC": "LTC", "XXLM": "XLM",
        "XXMR": "XMR", "XXRP": "XRP", "XZEC": "ZEC", "ZUSD": "USD",
        "ZEUR": "EUR",  "ZGBP": "GBP", "ZCAD": "CAD", "ZJPY": "JPY",
    ]
    return map[raw] ?? (raw.count == 4 && (raw.hasPrefix("X") || raw.hasPrefix("Z")) ? String(raw.dropFirst()) : raw)
}

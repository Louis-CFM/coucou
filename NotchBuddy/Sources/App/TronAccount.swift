import Foundation

/// One balance read from a TronGrid account answer (TRX or a known TRC-20 token).
struct TronHolding: Equatable, Sendable {
    let symbol: String
    let amount: Double
}

/// Pure parsing of `GET https://api.trongrid.io/v1/accounts/ADDRESS`, kept free of
/// AppKit/Keychain so `scripts/test-portfolio-tron.sh` can compile it alone.
enum TronAccount {
    /// Well-known TRC-20 contracts that have a Coinbase USD price (or are stable coins).
    /// Symbol and decimals checked on-chain (`symbol()` / `decimals()` via TronGrid) and on Tronscan.
    /// Unknown contracts (airdropped spam tokens included) are skipped on purpose.
    static let knownTokens: [String: (symbol: String, decimals: Int)] = [
        "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t": ("USDT", 6),   // Tether USD
        "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8": ("USDC", 6),   // Tronscan labels this contract "USD Coin Old" (Circle); the price still comes from Coinbase USDC
    ]

    /// TRX first (0 when the account has no `balance`), then the known TRC-20 tokens in first-seen order.
    /// One holding per symbol: a repeated contract (or two contracts sharing a symbol) is summed, because
    /// `PortfolioHolding.id` is the symbol and duplicate ids break the SwiftUI ForEach.
    static func parse(_ json: [String: Any]) -> [TronHolding] {
        let account = (json["data"] as? [[String: Any]])?.first
        let sun = (account?["balance"] as? NSNumber)?.doubleValue ?? 0
        var order = ["TRX"]
        var totals = ["TRX": sun / 1e6]
        // trc20 is a list of one-entry dictionaries: contract -> raw amount as a string.
        for entry in (account?["trc20"] as? [[String: Any]]) ?? [] {
            for (contract, raw) in entry {
                // Digits only: Decimal(string:) would accept "12abc" (12), "-7" and "1e3".
                guard let token = knownTokens[contract],
                      let rawString = raw as? String,
                      !rawString.isEmpty,
                      rawString.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let units = Decimal(string: rawString) else { continue }
                var scale = Decimal(1)
                for _ in 0..<token.decimals { scale *= 10 }
                let amount = NSDecimalNumber(decimal: units / scale).doubleValue
                if totals[token.symbol] == nil { order.append(token.symbol) }
                totals[token.symbol, default: 0] += amount
            }
        }
        return order.map { TronHolding(symbol: $0, amount: totals[$0] ?? 0) }
    }
}

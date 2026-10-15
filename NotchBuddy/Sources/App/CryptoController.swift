import Foundation
import Combine

// MARK: - Crypto quote

/// A coin's price on the chosen exchange, its price 24 h ago and the last 24 hourly closes.
struct CryptoQuote: Identifiable, Equatable, Sendable {
    let symbol: String
    let price: Double
    let open24h: Double
    /// Hourly closes over the last 24 h, oldest first (empty until the candles are read).
    var spark: [Double] = []

    var id: String { symbol }

    /// Change over 24 h, in percent.
    var change: Double { open24h > 0 ? (price - open24h) / open24h * 100 : 0 }
}

// MARK: - Exchange

/// Public market data of an exchange: no account, no key.
enum CryptoExchange: String, CaseIterable, Sendable {
    case coinbase, okx

    var name: String {
        switch self {
        case .coinbase: return "Coinbase"
        case .okx:      return "OKX"
        }
    }

    /// Trading pair for a coin in a currency. OKX quotes dollars in USDT.
    func pair(_ symbol: String, _ currency: String) -> String {
        switch self {
        case .coinbase: return "\(symbol)-\(currency)"
        case .okx:      return "\(symbol)-\(currency == "USD" ? "USDT" : currency)"
        }
    }

    func tickerURL(_ pair: String) -> URL? {
        switch self {
        case .coinbase: return URL(string: "https://api.exchange.coinbase.com/products/\(pair)/stats")
        case .okx:      return URL(string: "https://www.okx.com/api/v5/market/ticker?instId=\(pair)")
        }
    }

    func candlesURL(_ pair: String) -> URL? {
        switch self {
        case .coinbase: return URL(string: "https://api.exchange.coinbase.com/products/\(pair)/candles?granularity=3600")
        case .okx:      return URL(string: "https://www.okx.com/api/v5/market/candles?instId=\(pair)&bar=1H&limit=24")
        }
    }

    /// The coin's market page on the exchange's site.
    func tradeURL(_ pair: String) -> URL? {
        switch self {
        case .coinbase: return URL(string: "https://www.coinbase.com/advanced-trade/spot/\(pair)")
        case .okx:      return URL(string: "https://www.okx.com/trade-spot/\(pair.lowercased())")
        }
    }

    /// (price, price 24 h ago) from the ticker answer.
    func parseTicker(_ data: Data) -> (Double, Double)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        switch self {
        case .coinbase:
            guard let d = json as? [String: Any],
                  let last = Self.number(d["last"]), let open = Self.number(d["open"]) else { return nil }
            return (last, open)
        case .okx:
            guard let d = json as? [String: Any], (d["code"] as? String) == "0",
                  let row = (d["data"] as? [[String: Any]])?.first,
                  let last = Self.number(row["last"]), let open = Self.number(row["open24h"]) else { return nil }
            return (last, open)
        }
    }

    /// Hourly closes, oldest first, from the candles answer (both exchanges send newest first).
    func parseCandles(_ data: Data) -> [Double] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [[Any]]
        switch self {
        case .coinbase: rows = (json as? [[Any]]) ?? []
        case .okx:      rows = ((json as? [String: Any])?["data"] as? [[Any]]) ?? []
        }
        // Close: index 4 on both (Coinbase: time, low, high, open, close; OKX: ts, o, h, l, c).
        let closes = rows.prefix(24).compactMap { $0.count > 4 ? Self.number($0[4]) : nil }
        return closes.reversed()
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}

// MARK: - Crypto settings

enum CryptoSettings {
    static let exchangeKey = "cryptoExchange"
    static let currencyKey = "cryptoCurrency"
    static let coinsKey = "cryptoCoins"
    static let alertKey = "cryptoAlertEnabled"
    static let alertPercentKey = "cryptoAlertPercent"

    static let defaultCoins = "BTC, ETH, SOL"
    static let maxCoins = 8

    static var exchange: CryptoExchange {
        CryptoExchange(rawValue: UserDefaults.standard.string(forKey: exchangeKey) ?? "") ?? .coinbase
    }
    static var currency: String {
        let c = UserDefaults.standard.string(forKey: currencyKey) ?? "EUR"
        return c == "USD" ? "USD" : "EUR"
    }
    /// "btc, Eth;sol" → ["BTC", "ETH", "SOL"]: letters and digits only, no repeats.
    static func parseCoins(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count <= 10 && seen.insert($0).inserted }
            .prefix(maxCoins)
            .map { $0 }
    }
    static var coins: [String] {
        parseCoins(UserDefaults.standard.string(forKey: coinsKey) ?? defaultCoins)
    }
    static var alertEnabled: Bool { UserDefaults.standard.bool(forKey: alertKey) }
    static var alertPercent: Double {
        let v = UserDefaults.standard.double(forKey: alertPercentKey)
        return v > 0 ? v : 5
    }
}

// MARK: - Crypto Controller

/// Prices of the coins the user picked, from Coinbase or OKX public market data (no key,
/// no account). Read every 60 s and the 24 h curve every 10 min, only while the pill is
/// on: nothing goes over the network otherwise. An opt-in alert reveals the island when a
/// coin moves more than the chosen percentage since the last alert.
@MainActor
final class CryptoController: ObservableObject {
    static let shared = CryptoController()
    nonisolated static let pillId = "integration_crypto"

    /// Quotes in the order the coins were listed; a coin the exchange doesn't list is absent.
    @Published private(set) var quotes: [CryptoQuote] = []
    /// Coins the exchange did not answer for (unknown pair, or no network).
    @Published private(set) var missing: [String] = []
    @Published private(set) var loaded = false
    @Published private(set) var lastUpdate: Date?
    /// The coin that set off the last alert, for the card to show it first.
    @Published private(set) var alertSymbol: String?

    private var timer: Timer?
    private var fetching = false
    private var lastCandles: Date = .distantPast
    /// Price each coin had at the last alert (or when first seen).
    private var reference: [String: Double] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var lastSettings = ""

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    private init() {
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] _ in
                // The sink runs before the property changes: decide on the next turn.
                DispatchQueue.main.async { self?.updatePolling() }
            }
            .store(in: &cancellables)
    }

    func start() { updatePolling() }

    /// Exchange, currency or coins changed in Settings: start over with the new list.
    func settingsChanged() {
        let key = "\(CryptoSettings.exchange.rawValue)|\(CryptoSettings.currency)|\(CryptoSettings.coins.joined(separator: ","))"
        guard key != lastSettings else { return }
        lastSettings = key
        quotes = []
        missing = []
        loaded = false
        reference = [:]
        lastCandles = .distantPast
        refresh()
    }

    private func updatePolling() {
        if isPillActive {
            if timer == nil {
                let t = Timer(timeInterval: 60, repeats: true) { _ in
                    MainActor.assumeIsolated { CryptoController.shared.refresh() }
                }
                t.tolerance = 10
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
            lastSettings = "\(CryptoSettings.exchange.rawValue)|\(CryptoSettings.currency)|\(CryptoSettings.coins.joined(separator: ","))"
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            quotes = []
            missing = []
            loaded = false
            lastUpdate = nil
            reference = [:]
            alertSymbol = nil
            lastCandles = .distantPast
        }
    }

    func refreshIfStale(minAge: TimeInterval = 20) {
        guard Date().timeIntervalSince(lastUpdate ?? .distantPast) > minAge else { return }
        refresh()
    }

    func refresh() {
        guard isPillActive, !fetching else { return }
        let exchange = CryptoSettings.exchange
        let currency = CryptoSettings.currency
        let coins = CryptoSettings.coins
        guard !coins.isEmpty else {
            quotes = []; missing = []; loaded = true
            return
        }
        let withCandles = Date().timeIntervalSince(lastCandles) > 600
        fetching = true
        Task {
            var fresh: [CryptoQuote] = []
            var notFound: [String] = []
            await withTaskGroup(of: (Int, CryptoQuote?).self) { group in
                for (i, coin) in coins.enumerated() {
                    group.addTask {
                        (i, await Self.fetch(coin, exchange: exchange, currency: currency, candles: withCandles))
                    }
                }
                var byIndex: [Int: CryptoQuote] = [:]
                for await (i, q) in group {
                    if let q { byIndex[i] = q } else { notFound.append(coins[i]) }
                }
                fresh = coins.indices.compactMap { byIndex[$0] }
            }
            fetching = false
            // Keep the previous curve until a new one is read.
            let previous = Dictionary(uniqueKeysWithValues: quotes.map { ($0.symbol, $0.spark) })
            for i in fresh.indices where fresh[i].spark.isEmpty {
                fresh[i].spark = previous[fresh[i].symbol] ?? []
            }
            if withCandles && !fresh.isEmpty { lastCandles = Date() }
            if fresh != quotes { quotes = fresh }
            missing = notFound.sorted { (coins.firstIndex(of: $0) ?? 0) < (coins.firstIndex(of: $1) ?? 0) }
            loaded = true
            lastUpdate = Date()
            checkAlerts()
        }
    }

    private nonisolated static func fetch(_ coin: String, exchange: CryptoExchange, currency: String,
                                          candles: Bool) async -> CryptoQuote? {
        let pair = exchange.pair(coin, currency)
        guard let url = exchange.tickerURL(pair) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let (price, open) = exchange.parseTicker(data) else { return nil }
        var quote = CryptoQuote(symbol: coin, price: price, open24h: open)
        if candles, let curl = exchange.candlesURL(pair) {
            var creq = URLRequest(url: curl, timeoutInterval: 10)
            creq.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (cdata, cresp) = try? await URLSession.shared.data(for: creq),
               (cresp as? HTTPURLResponse)?.statusCode == 200 {
                quote.spark = exchange.parseCandles(cdata)
            }
        }
        return quote
    }

    // MARK: - Alerts

    /// A coin that moved more than the chosen percentage since the last alert (or since it
    /// was first seen) plays a sound and reveals the island on the Crypto pill. Off by default.
    private func checkAlerts() {
        for q in quotes {
            guard let ref = reference[q.symbol], ref > 0 else {
                reference[q.symbol] = q.price
                continue
            }
            let move = abs(q.price - ref) / ref * 100
            guard CryptoSettings.alertEnabled, move >= CryptoSettings.alertPercent else { continue }
            reference[q.symbol] = q.price
            alertSymbol = q.symbol
            let state = AppState.shared
            if state.mode != .expanded, state.tasks.contains(where: { $0.id == Self.pillId }) {
                state.focusId = Self.pillId
            }
            NotificationCenter.default.post(name: .hookReveal, object: nil)
            break   // one alert at a time
        }
    }

    // MARK: - Formatting

    /// "62 140 €", "3 120,55 €", "0,4312 $" in the user's locale.
    static func format(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        let digits = value >= 1000 ? 0 : value >= 1 ? 2 : 4
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    static func formatChange(_ pct: Double) -> String {
        String(format: "%@%.2f %%", pct >= 0 ? "+" : "−", abs(pct))
    }
}

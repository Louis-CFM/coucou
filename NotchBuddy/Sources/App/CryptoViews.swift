import SwiftUI
import AppKit

// MARK: - Crypto card

/// The coins picked in Settings with their price, 24 h curve and 24 h change, from Coinbase
/// or OKX public data. Three in view, the rest a scroll away; a click opens the coin's page
/// on the exchange.
struct CryptoCardView: View {
    @ObservedObject private var crypto = CryptoController.shared

    private var accent: Color {
        Color(hex: PillCatalog.definition(for: CryptoController.pillId)?.color ?? "#F7931A")
    }

    /// The coin of the last alert first, then the others in their order.
    private var ordered: [CryptoQuote] {
        guard let s = crypto.alertSymbol, let i = crypto.quotes.firstIndex(where: { $0.symbol == s }) else {
            return crypto.quotes
        }
        var q = crypto.quotes
        q.insert(q.remove(at: i), at: 0)
        return q
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                Text(verbatim: "Crypto")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text(verbatim: CryptoSettings.exchange.name)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                Text(verbatim: "24h")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                Spacer(minLength: 2)
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            if crypto.quotes.isEmpty {
                Group {
                    if !crypto.loaded {
                        Text("Loading…")
                    } else if CryptoSettings.coins.isEmpty {
                        Text("crypto.no-coins")
                    } else {
                        Text(String(format: String(localized: "crypto.unavailable %@"),
                                    CryptoSettings.exchange.name))
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
                .padding(.top, 8)
                .padding(.leading, 116)
                .padding(.trailing, 12)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(ordered) { quote in
                            CryptoRow(quote: quote, highlighted: quote.symbol == crypto.alertSymbol)
                        }
                        if !crypto.missing.isEmpty {
                            Text(String(format: String(localized: "crypto.not-listed %@"),
                                        crypto.missing.joined(separator: ", ")))
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#4D5159"))
                                .lineLimit(1).truncationMode(.tail)
                                .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.top, 5)
                .padding(.leading, 108)
                .padding(.trailing, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .onAppear { crypto.refreshIfStale() }
    }
}

/// One coin: symbol, 24 h curve, price, change. A click opens its page on the exchange.
private struct CryptoRow: View {
    let quote: CryptoQuote
    let highlighted: Bool
    @State private var hovered = false

    var body: some View {
        let up = quote.change >= 0
        let tone = Color(hex: up ? "#22C55E" : "#F4505E")
        Button {
            let exchange = CryptoSettings.exchange
            if let url = exchange.tradeURL(exchange.pair(quote.symbol, CryptoSettings.currency)) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: quote.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .lineLimit(1)
                    .frame(width: 30, alignment: .leading)
                CryptoSparkline(values: quote.spark, color: tone)
                    .frame(width: 30, height: 12)
                Spacer(minLength: 2)
                Text(verbatim: CryptoController.format(quote.price, currency: CryptoSettings.currency))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Text(verbatim: CryptoController.formatChange(quote.change))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(tone)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(highlighted ? tone.opacity(hovered ? 0.16 : 0.10)
                                      : Color.white.opacity(hovered ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The last 24 hourly closes as a thin line. Drawn once per new curve (no animation).
struct CryptoSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                let span = max(hi - lo, hi * 0.0001)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

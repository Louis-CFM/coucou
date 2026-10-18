import SwiftUI
import AppKit

// MARK: - Portfolio card

/// Real balances from connected exchange accounts and self-custody wallets.
/// Balances are fetched with read-only API keys or public wallet addresses.
struct PortfolioCardView: View {
    @ObservedObject private var portfolio = PortfolioController.shared

    private var accent: Color {
        Color(hex: PillCatalog.definition(for: PortfolioController.pillId)?.color ?? "#FFD700")
    }

    private var totalUSD: Double {
        portfolio.accounts.reduce(0) { $0 + $1.totalValueUSD }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                Text("Portfolio")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Spacer(minLength: 2)
                if portfolio.loaded && totalUSD > 0 {
                    Text(verbatim: PortfolioController.formatValue(totalUSD))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .monospacedDigit()
                }
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            if !portfolio.loaded {
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.top, 8)
                    .padding(.leading, 116)
                    .padding(.trailing, 12)
            } else if portfolio.accounts.isEmpty {
                Text(String(localized: "portfolio.no-accounts"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.top, 8)
                    .padding(.leading, 116)
                    .padding(.trailing, 12)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(portfolio.accounts) { account in
                            PortfolioAccountSection(account: account)
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
        .onAppear { portfolio.refreshIfStale() }
    }
}

// MARK: - Account section

private struct PortfolioAccountSection: View {
    let account: PortfolioAccount

    private var label: String {
        switch account.source {
        case .exchange(let k): return k.name
        case .wallet(let w):   return w.label
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Account label + value
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#8E939C"))
                Spacer(minLength: 2)
                if let err = account.fetchError {
                    Text(verbatim: err)
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#F4505E"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if account.totalValueUSD > 0 {
                    Text(verbatim: PortfolioController.formatValue(account.totalValueUSD))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)

            if account.fetchError == nil {
                ForEach(account.holdings.sorted(by: { $0.value > $1.value })) { holding in
                    PortfolioHoldingRow(holding: holding)
                }
            }
        }
    }
}

// MARK: - Holding row

private struct PortfolioHoldingRow: View {
    let holding: PortfolioHolding
    @State private var hovered = false

    private var changeColor: Color {
        guard let ch = holding.change24h else { return Color(hex: "#8E939C") }
        return ch >= 0 ? Color(hex: "#4CAF50") : Color(hex: "#F4505E")
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: holding.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#E8E9EC"))
                .lineLimit(1)
                .frame(width: 36, alignment: .leading)
            Text(verbatim: PortfolioController.formatAmount(holding.amount))
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#8E939C"))
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 2)
            if holding.priceHistory.count >= 2 {
                let positive = holding.change24h.map { $0 >= 0 } ?? true
                SparklineView(prices: holding.priceHistory, positive: positive)
                    .frame(width: 36, height: 14)
            }
            if let ch = holding.change24h {
                Text(String(format: ch >= 0 ? "+%.1f%%" : "%.1f%%", ch))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(changeColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if holding.price > 0 {
                Text(verbatim: PortfolioController.formatValue(holding.value))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(hovered ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

// MARK: - Sparkline

private struct SparklineView: View {
    let prices: [Double]
    let positive: Bool

    var body: some View {
        GeometryReader { geo in
            let mn = prices.min() ?? 0, mx = prices.max() ?? 1
            let range = mx - mn == 0 ? 1.0 : mx - mn
            let w = geo.size.width, h = geo.size.height
            let n = prices.count
            Path { path in
                for (i, p) in prices.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(n - 1)
                    let y = h - h * CGFloat((p - mn) / range)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else       { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(
                positive ? Color(hex: "#4CAF50") : Color(hex: "#F4505E"),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

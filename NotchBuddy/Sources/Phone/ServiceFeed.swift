import SwiftUI
import UIKit

// The latest news of every service Mochi (a payment, a deploy, a pull request, a meeting…),
// one feed under the agents: the first page shows more than the sessions running on the Mac.

/// One piece of news from a service.
struct FeedEntry: Identifiable, Equatable {
    let id: String
    let pillId: String
    let item: ServiceItem
    /// Where it goes in the feed: its own date when it has one in the past, else the moment the
    /// Mac last fetched the service (pull requests have no date, meetings are in the future).
    let sortDate: Date
}

enum ServiceFeed {
    /// The services first in line when news come at the same time.
    static let priority = ["integration_stripe", "integration_vercel", "integration_github"]

    /// The newest news first: a few per service, so one busy service doesn't hide the others.
    static func entries(from services: [String: ServiceSnapshot], perService: Int = 3, total: Int = 10,
                        now: Date = Date()) -> [FeedEntry] {
        var out: [FeedEntry] = []
        for (pillId, snapshot) in services {
            let items = snapshot.sections.flatMap { section in section.items.prefix(perService) }
            for (index, item) in items.prefix(perService).enumerated() {
                let date = item.date.flatMap { $0 <= now ? $0 : nil } ?? snapshot.updatedAt
                out.append(FeedEntry(id: "\(pillId)#\(index)#\(item.title)", pillId: pillId, item: item,
                                     sortDate: date))
            }
        }
        return Array(out.sorted { a, b in
            if a.sortDate != b.sortDate { return a.sortDate > b.sortDate }
            return rank(a.pillId) < rank(b.pillId)
        }.prefix(total))
    }

    private static func rank(_ pillId: String) -> Int {
        priority.firstIndex(of: pillId) ?? priority.count
    }
}

/// The feed's section in the Agents tab.
struct ServiceFeedSection: View {
    let link: PhoneLink

    private var entries: [FeedEntry] { ServiceFeed.entries(from: link.services) }

    var body: some View {
        Section {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No news yet")
                        .font(.subheadline.weight(.semibold))
                    Text("Connect Stripe, Vercel or GitHub in Coucou on your Mac: their payments, deploys and pull requests show up here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            ForEach(entries) { entry in
                Button {
                    link.openPillId = entry.pillId
                } label: {
                    FeedRow(entry: entry, snapshot: link.services[entry.pillId])
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let url = entry.item.url.flatMap(URL.init(string:)) {
                        Link(destination: url) { Label("Open in the browser", systemImage: "safari") }
                    }
                    Button {
                        UIPasteboard.general.string = [entry.item.title, entry.item.detail]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        } header: {
            Text("Latest from your services")
        }
        .animation(.spring(duration: 0.5, bounce: 0.2), value: entries.map(\.id))
    }
}

/// One piece of news: the service's Mochi, what happened, when.
struct FeedRow: View {
    let entry: FeedEntry
    let snapshot: ServiceSnapshot?

    private var color: String { PillCatalog.definition(for: entry.pillId)?.color ?? "#C0C4CC" }
    private var name: String { PillCatalog.definition(for: entry.pillId)?.name ?? entry.pillId }

    var body: some View {
        HStack(spacing: 12) {
            MochiStill(state: entry.item.tone == .ok ? .finished : entry.item.tone.botState,
                       bodyHex: color, showBadge: false)
                .padding(4)
                .frame(width: 40, height: 40)
                // A coloured Mochi on a neutral tile (as in the Services tab), its colour as a rim.
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color(hex: color).opacity(0.35), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(entry.item.detail.isEmpty ? name : "\(name) · \(entry.item.detail)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Circle()
                    .fill(entry.item.tone.color)
                    .frame(width: 8, height: 8)
                Text(entry.item.date ?? entry.sortDate, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

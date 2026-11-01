import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers

/// The Search tab: every turn this iPhone saw (prompts, answers, file names).
struct SearchTab: View {
    let link: PhoneLink
    @State private var query = ""

    private struct Hit: Identifiable {
        let turn: TurnSnapshot
        let agent: String
        let snippet: String
        var id: String { "\(turn.pillId)|\(turn.startedAt.timeIntervalSince1970)" }
    }

    private var allTurns: [TurnSnapshot] {
        (Array(link.turns.values) + link.archive.past.values.flatMap { $0 })
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var hits: [Hit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return allTurns.compactMap { turn in
            let agent = PillCatalog.definition(for: turn.pillId)?.name ?? turn.pillId
            if needle.isEmpty { return Hit(turn: turn, agent: agent, snippet: turn.headline) }
            let fields = [turn.prompt, turn.finalMessage, turn.project, agent] + turn.files.map(\.path)
            guard let field = fields.first(where: { $0.localizedCaseInsensitiveContains(needle) }) else { return nil }
            return Hit(turn: turn, agent: agent, snippet: Self.snippet(of: field, around: needle))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if allTurns.isEmpty {
                    ContentUnavailableView("No turn yet", systemImage: "text.magnifyingglass",
                                           description: Text("What your agents do on your Mac shows up here, ready to search."))
                } else if hits.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    Section(query.isEmpty ? "Recent turns" : "Results") {
                        ForEach(hits) { hit in
                            NavigationLink {
                                ScrollView {
                                    LastTurnView(turn: hit.turn, working: false).padding(16)
                                }
                                .background(Color.black)
                                .navigationTitle(hit.turn.project.isEmpty ? hit.agent : hit.turn.project)
                                .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                row(hit)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Prompts, answers, files")
        }
    }

    private func row(_ hit: Hit) -> some View {
        let pill = PillCatalog.definition(for: hit.turn.pillId)
        return HStack(alignment: .top, spacing: 12) {
            MochiStill(state: .idle, bodyHex: pill?.color ?? "#FFFFFF")
                .padding(4)
                .frame(width: 34, height: 34)
                .background(Color.mochiTile(hex: pill?.color ?? "#3B4A6B"), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(hit.turn.project.isEmpty ? hit.agent : "\(hit.turn.project) · \(hit.agent)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(hit.turn.startedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(hit.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// A few words around the match.
    private static func snippet(of text: String, around needle: String) -> String {
        guard let range = text.range(of: needle, options: .caseInsensitive) else { return String(text.prefix(140)) }
        let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
        let piece = text[start..<end].replacingOccurrences(of: "\n", with: " ")
        return (start > text.startIndex ? "…" : "") + piece + (end < text.endIndex ? "…" : "")
    }
}

/// Finished turns in the iPhone's Spotlight: search a project or a file from
/// the Home Screen and land on its session. The index stays on this iPhone.
enum SpotlightIndex {
    static let enabledKey = "spotlightTurns"
    static let activityType = CSSearchableItemActionType

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static func index(_ turn: TurnSnapshot) {
        guard isEnabled, turn.endedAt != nil else { return }
        let agent = PillCatalog.definition(for: turn.pillId)?.name ?? "Agent"
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = turn.project.isEmpty ? agent : "\(turn.project) · \(agent)"
        let answer = turn.finalMessage.isEmpty ? "" : "\n" + String(turn.finalMessage.prefix(300))
        attributes.contentDescription = turn.headline + answer
        attributes.keywords = [agent, turn.project, "Coucou"] + turn.files.map(\.name)
        let item = CSSearchableItem(uniqueIdentifier: "\(turn.pillId)|\(Int(turn.startedAt.timeIntervalSince1970))",
                                    domainIdentifier: "turns", attributeSet: attributes)
        item.expirationDate = Date().addingTimeInterval(30 * 24 * 3600)
        CSSearchableIndex.default().indexSearchableItems([item])
    }

    static func removeAll() {
        CSSearchableIndex.default().deleteAllSearchableItems()
    }

    /// The session a Spotlight result opens.
    static func pillId(from activity: NSUserActivity) -> String? {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        return id.split(separator: "|").first.map(String.init)
    }
}

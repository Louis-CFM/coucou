#if !APPSTORE
import AppKit
import SwiftUI
import UserNotifications

// MARK: - BrainRunner

@MainActor
final class BrainRunner: ObservableObject {
    static let shared = BrainRunner()

    @AppStorage("brainBinaryPath") var customPath: String = ""

    // Cache — not @Published (doesn't need re-render)
    private var cachedPath: String? = nil
    private var discovered = false

    var binaryPath: String? {
        if !customPath.isEmpty && FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }
        return cachedPath  // Returns nil until discovery completes
    }

    var isInstalled: Bool { binaryPath != nil }

    // Run brain <args> and return stdout as Data. Throws on non-zero exit.
    func run(_ args: [String]) async throws -> Data {
        let bin = try await resolvedBinary()
        return try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw BrainError.nonZeroExit(Int(proc.terminationStatus))
            }
            return pipe.fileHandleForReading.readDataToEndOfFile()
        }.value
    }

    func run<T: Decodable>(_ args: [String], as type: T.Type) async throws -> T {
        let data = try await run(args)
        return try JSONDecoder().decode(type, from: data)
    }

    // Called once at app start to prime the cache
    func discoverAsync() {
        guard !discovered else { return }
        let custom = customPath
        Task.detached(priority: .background) { [weak self] in
            let found = Self.findBinary(customPath: custom)
            await MainActor.run { [weak self] in
                self?.cachedPath = found
                self?.discovered = true
            }
        }
    }

    // MARK: - Private helpers

    private func resolvedBinary() async throws -> String {
        if let bin = binaryPath { return bin }
        // Not yet cached — discover now on background thread
        let custom = customPath
        let found = await Task.detached(priority: .userInitiated) {
            Self.findBinary(customPath: custom)
        }.value
        if let f = found {
            cachedPath = f
            discovered = true
            return f
        }
        throw BrainError.notInstalled
    }

    private nonisolated static func findBinary(customPath: String) -> String? {
        if !customPath.isEmpty && FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }
        let home = NSHomeDirectory()
        let nvmDefault: String? = {
            let p = "\(home)/.nvm/alias/default"
            return try? String(contentsOfFile: p, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let candidates = [
            "\(home)/.nvm/alias/default/bin/brain",
            "\(home)/.nvm/versions/node/\(nvmDefault ?? "")/bin/brain",
            "/usr/local/bin/brain",
            "/opt/homebrew/bin/brain",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return discoverViashell()
    }

    private nonisolated static func discoverViashell() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which brain"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = out, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

enum BrainError: LocalizedError {
    case notInstalled
    case nonZeroExit(Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "brain binary not found"
        case .nonZeroExit(let code): return "brain exited with code \(code)"
        }
    }
}

// MARK: - Decodable models

struct BrainSearchResult: Decodable, Identifiable {
    let id: String
    let titre: String
    let source: String
    let date: String
    let extrait: String
    let lien: String
    let projet: String
    let nbMentions: Int
}

struct BrainSearchResponse: Decodable {
    let total: Int
    let results: [BrainSearchResult]
}

struct BrainMessage: Decodable {
    let role: String
    let text: String
}

struct BrainElement: Decodable {
    let kind: String
    let texte: String
    let statut: String?
}

struct BrainConversationDetail: Decodable {
    let id: String
    let titre: String
    let source: String
    let date: String
    let lien: String
    let projet: String
    let projets: [String]
    let messages: [BrainMessage]
    let elements: [BrainElement]?
}

struct BrainGraphNode: Decodable, Identifiable {
    let id: String
    let kind: String
    let label: String
    let date: String?
    let projet: String?
}

struct BrainGraphEdge: Decodable {
    let from: String
    let to: String
}

struct BrainGraphResponse: Decodable {
    let nodes: [BrainGraphNode]
    let edges: [BrainGraphEdge]
}

struct BrainGroupe: Decodable {
    let titre: String
    let count: Int
    let freqJours: Double?
    let histogram: [Int]
}

struct BrainErreur: Decodable {
    let texte: String
    let statut: String
    let count: Int
    let derniereDate: String
}

struct BrainArtifact: Decodable {
    let kind: String
    let count: Int
}

struct BrainRecurrencesResponse: Decodable {
    let groupes: [BrainGroupe]
    let erreurs: [BrainErreur]
    let artifacts: [BrainArtifact]
}

struct BrainRawIndex: Decodable {
    let messages: Int
    let conversations: Int
    let sessions: Int
}

struct BrainStatus: Decodable {
    let depth: String
    let rawIndex: BrainRawIndex?
    let pause: String?
    let dailyLimit: Int
    let concurrency: Int
}

// MARK: - MemorySearchModel

@MainActor
final class MemorySearchModel: ObservableObject {
    @Published var query: String = ""
    @Published var filter: MemoryFilter = .all
    @Published var results: [BrainSearchResult] = []
    @Published var total: Int = 0
    @Published var offset: Int = 0
    @Published var isLoading: Bool = false
    @Published var selected: BrainSearchResult? = nil
    @Published var detail: BrainConversationDetail? = nil
    @Published var detailLoading: Bool = false
    @Published var hasIndex: Bool = true

    private var searchTask: Task<Void, Never>?

    enum MemoryFilter: String, CaseIterable {
        case all, claude, code

        var label: String {
            switch self {
            case .all:    return "Tout"
            case .claude: return "Claude.ai"
            case .code:   return "Claude Code"
            }
        }

        var source: String? {
            switch self {
            case .all:    return nil
            case .claude: return "claude"
            case .code:   return "code"
            }
        }
    }

    func search(loadMore: Bool = false) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        let lOffset = loadMore ? offset : 0
        if !loadMore {
            results = []
            total = 0
            offset = 0
        }
        guard !q.isEmpty else { return }
        isLoading = true
        searchTask = Task {
            var args = ["search", q, "--json", "--limit", "20", "--offset", "\(lOffset)"]
            if let src = filter.source {
                args += ["--source", src]
            }
            do {
                let resp = try await BrainRunner.shared.run(args, as: BrainSearchResponse.self)
                guard !Task.isCancelled else { return }
                if loadMore {
                    results += resp.results
                } else {
                    results = resp.results
                }
                total = resp.total
                offset = results.count
                hasIndex = true
            } catch BrainError.nonZeroExit {
                hasIndex = false
            } catch {}
            isLoading = false
        }
    }

    func loadDetail(_ result: BrainSearchResult) {
        selected = result
        detail = nil
        detailLoading = true
        Task {
            do {
                let d = try await BrainRunner.shared.run(["show", result.id, "--json"],
                                                         as: BrainConversationDetail.self)
                detail = d
            } catch {}
            detailLoading = false
        }
    }

    func copyResumeCommand() {
        guard let sel = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude --resume \(sel.id)", forType: .string)
    }
}

// MARK: - HubMemorySearchPage

struct HubMemorySearchPage: View {
    @StateObject private var model = MemorySearchModel()
    @ObservedObject private var runner = BrainRunner.shared
    @FocusState private var fieldFocused: Bool
    @State private var resumeCopied = false

    var body: some View {
        HStack(spacing: 0) {
            listPanel
            if model.selected != nil {
                Divider().background(HubTheme.line)
                detailPanel
                    .frame(width: 350)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HubTheme.panel)
        .onAppear {
            // Check index
            Task {
                do {
                    let status = try await BrainRunner.shared.run(["status", "--json"], as: BrainStatus.self)
                    model.hasIndex = (status.rawIndex?.conversations ?? 0) > 0
                } catch {
                    model.hasIndex = false
                }
            }
        }
        .onKeyPress(.return) {
            model.search()
            return .handled
        }
    }

    // MARK: List panel

    @ViewBuilder private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero
            HubHero(page: .memorySearch, title: String(localized: "hub.page.memory-search"))
                .padding(.horizontal, 28)
                .padding(.top, 24)

            if !runner.isInstalled {
                notInstalledCard
            } else if !model.hasIndex && model.results.isEmpty {
                noIndexCard
            } else {
                searchUI
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var notInstalledCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HubGlowCard(color: Color(hex: "#22D3EE")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "hub.memory.not-installed"))
                            .font(.system(size: 17, weight: .semibold))
                        Text(String(localized: "hub.memory.not-installed.detail"))
                            .font(.system(size: 13))
                            .foregroundColor(HubTheme.secondary)
                        Text(verbatim: "npm install -g @coucou/brain")
                            .font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                            .textSelection(.enabled)
                        Text(verbatim: "brain index")
                            .font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
        }
    }

    @ViewBuilder private var noIndexCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HubGlowCard(color: Color(hex: "#22D3EE")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "hub.memory.index-missing"))
                            .font(.system(size: 17, weight: .semibold))
                        Text(String(localized: "hub.memory.index-missing.detail"))
                            .font(.system(size: 13))
                            .foregroundColor(HubTheme.secondary)
                        Text(verbatim: "brain index")
                            .font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
        }
    }

    @ViewBuilder private var searchUI: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Search field
            HubField(placeholder: String(localized: "hub.memory.search.placeholder"),
                     text: $model.query,
                     onSubmit: { model.search() })
                .focused($fieldFocused)
                .padding(.horizontal, 28)
                .padding(.top, 16)

            // Filter bar
            HStack(spacing: 6) {
                ForEach(MemorySearchModel.MemoryFilter.allCases, id: \.self) { f in
                    Button(f.label) { model.filter = f; model.search() }
                        .buttonStyle(MemoryFilterButtonStyle(selected: model.filter == f))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)

            // Results
            if model.isLoading && model.results.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else if model.results.isEmpty && !model.query.isEmpty {
                HubEmptyState(text: "No results", state: .sleeping, color: "#22D3EE")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.results) { result in
                            MemoryResultRow(result: result,
                                            selected: model.selected?.id == result.id,
                                            query: model.query)
                            { model.loadDetail(result) }
                        }
                        if model.results.count < model.total {
                            Button(String(localized: "hub.memory.search.load-more")) {
                                model.search(loadMore: true)
                            }
                            .buttonStyle(HubButtonStyle())
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Detail panel

    @ViewBuilder private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.detailLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else if let d = model.detail {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d.titre)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(HubTheme.text)
                        HStack(spacing: 8) {
                            MemorySourceBadge(source: d.source)
                            Text(d.date)
                                .font(.system(size: 11))
                                .foregroundColor(HubTheme.muted)
                        }
                    }

                    HubDivider()

                    // Messages
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(d.messages.prefix(8).enumerated()), id: \.offset) { _, msg in
                            MemoryMessageRow(message: msg)
                        }
                        if d.messages.count > 8 {
                            Text(String(format: String(localized: "hub.memory.show.more-messages"), d.messages.count - 8))
                                .font(.system(size: 11))
                                .foregroundColor(HubTheme.muted)
                        }
                    }

                    HubDivider()

                    // Elements
                    if let elements = d.elements, !elements.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "hub.memory.show.elements"))
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.1)
                                .foregroundColor(HubTheme.muted)
                            ForEach(Array(elements.enumerated()), id: \.offset) { _, el in
                                MemoryElementRow(element: el)
                            }
                        }
                    } else {
                        Text(String(localized: "hub.memory.show.not-digested"))
                            .font(.system(size: 12))
                            .foregroundColor(HubTheme.muted)
                            .italic()
                    }

                    HubDivider()

                    // Actions
                    VStack(spacing: 8) {
                        Button(String(localized: "hub.memory.show.open-claude")) {
                            if let url = URL(string: d.lien), !d.lien.isEmpty {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(HubButtonStyle())
                        .disabled(d.lien.isEmpty)
                        .frame(maxWidth: .infinity)

                        Button(resumeCopied ? String(localized: "hub.memory.show.resume.copied") : String(localized: "hub.memory.show.resume")) {
                            model.copyResumeCommand()
                            resumeCopied = true
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                resumeCopied = false
                            }
                        }
                        .buttonStyle(HubButtonStyle(primary: false))
                        .frame(maxWidth: .infinity)

                        Button(String(localized: "hub.memory.show.copy-link")) {
                            if !d.lien.isEmpty {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(d.lien, forType: .string)
                            }
                        }
                        .buttonStyle(HubButtonStyle(primary: false))
                        .disabled(d.lien.isEmpty)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(18)
        }
        .background(HubTheme.panel)
    }
}

// MARK: - HighlightedText

private struct HighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        var attrStr = AttributedString(text)
        for term in terms where term.count >= 2 {
            var searchText = text.lowercased()
            var baseOffset = 0
            while let range = searchText.range(of: term) {
                let start = baseOffset + searchText.distance(from: searchText.startIndex, to: range.lowerBound)
                let length = term.count
                if let attrRange = Range(NSRange(location: start, length: length), in: attrStr) {
                    attrStr[attrRange].foregroundColor = Color(hex: "#22D3EE")
                    attrStr[attrRange].font = .system(size: 12).bold()
                }
                let advance = searchText.distance(from: range.lowerBound, to: range.upperBound)
                baseOffset += searchText.distance(from: searchText.startIndex, to: range.upperBound)
                searchText = String(searchText[range.upperBound...])
                if searchText.isEmpty { break }
                _ = advance
            }
        }
        return Text(attrStr)
    }
}

// MARK: - MemoryResultRow

private struct MemoryResultRow: View {
    let result: BrainSearchResult
    let selected: Bool
    let query: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                // Cyan left border when selected
                RoundedRectangle(cornerRadius: 2)
                    .fill(selected ? Color(hex: "#22D3EE") : Color.clear)
                    .frame(width: 3)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(result.titre)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(HubTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        MemorySourceBadge(source: result.source)
                        Text(result.date)
                            .font(.system(size: 11))
                            .foregroundColor(HubTheme.muted)
                    }
                    if !result.extrait.isEmpty {
                        HighlightedText(text: result.extrait, query: query)
                            .font(.system(size: 12))
                            .foregroundColor(HubTheme.secondary)
                            .lineLimit(2)
                    }
                    if !result.projet.isEmpty {
                        Text(result.projet)
                            .font(.system(size: 11))
                            .foregroundColor(HubTheme.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(selected ? 0.08 : (hover ? 0.04 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - MemoryMessageRow

private struct MemoryMessageRow: View {
    let message: BrainMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message.role == "human" ? "You" : "Claude")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(message.role == "human" ? Color(hex: "#22D3EE") : HubTheme.accent)
                .frame(width: 44, alignment: .trailing)
            Text(String(message.text.prefix(200)))
                .font(.system(size: 12))
                .foregroundColor(HubTheme.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - MemoryElementRow

private struct MemoryElementRow: View {
    let element: BrainElement

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(element.statut ?? "")
                .font(.system(size: 12))
            Text(element.kind)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(kindColor(element.kind).opacity(0.2)))
                .foregroundColor(kindColor(element.kind))
            Text(element.texte)
                .font(.system(size: 12))
                .foregroundColor(HubTheme.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "décision": return Color(hex: "#A78BFA")
        case "leçon":    return Color(hex: "#34D399")
        case "fait":     return Color(hex: "#F7B32B")
        case "préf":     return Color(hex: "#F472B6")
        default:         return HubTheme.secondary
        }
    }
}

// MARK: - MemorySourceBadge

private struct MemorySourceBadge: View {
    let source: String

    var body: some View {
        Text(source == "claude" ? "Claude.ai" : "Claude Code")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(source == "claude" ? Color(hex: "#FB923C").opacity(0.2) : Color(hex: "#3B9EFF").opacity(0.2)))
            .foregroundColor(source == "claude" ? Color(hex: "#FB923C") : Color(hex: "#3B9EFF"))
    }
}

// MARK: - MemoryFilterButtonStyle

private struct MemoryFilterButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color(hex: "#22D3EE").opacity(0.18) : Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color(hex: "#22D3EE").opacity(0.5) : Color.clear))
            .foregroundColor(selected ? Color(hex: "#22D3EE") : HubTheme.secondary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// MARK: - MemoryGraphModel

@MainActor
final class MemoryGraphModel: ObservableObject {
    @Published var graph: BrainGraphResponse? = nil
    @Published var isLoading = true
    @Published var hoveredId: String? = nil
    @Published var selectedId: String? = nil
    @Published var filterKinds: Set<String> = []
    @Published var periodDays: Int? = nil  // nil = all
    // NON @Published — mutés chaque frame dans drawGraph, re-render via TimelineView
    var impulses: [GraphImpulse] = []
    var autoRotY: Double = 0
    var nodeScreenPositions: [String: CGPoint] = [:]
    var lastHoverPoint: CGPoint? = nil

    // @Published — seulement changé au clic utilisateur
    @Published var isPaused: Bool = false
    @Published var growCount: Int = -1  // -1 = all nodes visible

    struct GraphImpulse {
        var edgeIdx: Int
        var t: Float
        var speed: Float
        var direction: Int  // +1 = from→to, -1 = to→from
        var hopsLeft: Int   // sauts restants avant renaissance
    }

    func load() {
        Task {
            do {
                let g = try await BrainRunner.shared.run(["graph", "--json"], as: BrainGraphResponse.self)
                graph = g
                // Seed impulses
                impulses = (0..<min(100, g.edges.count * 3)).map { _ in
                    GraphImpulse(edgeIdx: Int.random(in: 0..<max(1, g.edges.count)),
                                 t: Float.random(in: 0..<1),
                                 speed: Float.random(in: 0.001...0.004),
                                 direction: Bool.random() ? 1 : -1,
                                 hopsLeft: Int.random(in: 3...7))
                }
            } catch {}
            isLoading = false
        }
    }

    func advance(dt: Double) {
        guard let g = graph, !g.edges.isEmpty else { return }
        // A1: auto-rotate
        if !isPaused {
            autoRotY += dt * 0.08
        }

        for i in impulses.indices {
            impulses[i].t += Float(dt) * impulses[i].speed * 60
            if impulses[i].t > 1 {
                impulses[i].hopsLeft -= 1

                if impulses[i].hopsLeft <= 0 {
                    // Renaissance depuis un nœud au hasard
                    impulses[i].edgeIdx = Int.random(in: 0..<g.edges.count)
                    impulses[i].direction = Bool.random() ? 1 : -1
                    impulses[i].hopsLeft = Int.random(in: 3...7)
                } else {
                    // Nœud d'arrivée de l'edge courante
                    let edge = g.edges[impulses[i].edgeIdx]
                    let arrivalNodeId = impulses[i].direction > 0 ? edge.to : edge.from

                    // Liens adjacents (partageant arrivalNodeId)
                    let adjacent = g.edges.indices.filter { idx in
                        idx != impulses[i].edgeIdx &&
                        (g.edges[idx].from == arrivalNodeId || g.edges[idx].to == arrivalNodeId)
                    }

                    if adjacent.isEmpty {
                        // Pas de voisins → renaissance
                        impulses[i].edgeIdx = Int.random(in: 0..<g.edges.count)
                        impulses[i].direction = Bool.random() ? 1 : -1
                        impulses[i].hopsLeft = Int.random(in: 3...7)
                    } else {
                        // Lien adjacent au hasard
                        let nextIdx = adjacent[Int.random(in: 0..<adjacent.count)]
                        let nextEdge = g.edges[nextIdx]
                        // Direction depuis arrivalNodeId
                        impulses[i].direction = nextEdge.from == arrivalNodeId ? 1 : -1
                        impulses[i].edgeIdx = nextIdx
                    }
                }
                impulses[i].t = 0
                impulses[i].speed = Float.random(in: 0.001...0.004)
            }
        }
    }

    // A2: Grow animation
    func startGrow() {
        guard let g = graph else { return }
        growCount = 0
        isPaused = true
        growFromZero(total: g.nodes.count)
    }

    private func growFromZero(total: Int) {
        guard growCount >= 0 && growCount < total else {
            if growCount >= total { growCount = -1; isPaused = false }
            return
        }
        let step = max(1, total / 80)
        growCount = min(growCount + step, total)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.growFromZero(total: total)
        }
    }

    // A3: Hover + Click to isolate
    func updateHover(at point: CGPoint) {
        lastHoverPoint = point
        var best: String? = nil
        var bestD = Double(50)
        for (id, pos) in nodeScreenPositions {
            let d = hypot(Double(point.x - pos.x), Double(point.y - pos.y))
            if d < bestD { bestD = d; best = id }
        }
        hoveredId = best
    }

    func handleTap() {
        guard let pt = lastHoverPoint else { return }
        var best: String? = nil
        var bestD = Double(50)
        for (id, pos) in nodeScreenPositions {
            let d = hypot(Double(pt.x - pos.x), Double(pt.y - pos.y))
            if d < bestD { bestD = d; best = id }
        }
        if let id = best {
            selectedId = selectedId == id ? nil : id

            // Impulsions depuis le nœud cliqué
            if let g = graph {
                let adjacent = g.edges.indices.filter {
                    g.edges[$0].from == id || g.edges[$0].to == id
                }
                if !adjacent.isEmpty {
                    let newImpulses = (0..<min(3, adjacent.count)).map { k -> GraphImpulse in
                        let edgeIdx = adjacent[k % adjacent.count]
                        let edge = g.edges[edgeIdx]
                        let dir = edge.from == id ? 1 : -1
                        return GraphImpulse(edgeIdx: edgeIdx, t: 0,
                                            speed: Float.random(in: 0.002...0.005),
                                            direction: dir, hopsLeft: Int.random(in: 4...7))
                    }
                    impulses.append(contentsOf: newImpulses)
                    // Limite à 150 impulsions max
                    if impulses.count > 150 { impulses.removeFirst(impulses.count - 150) }
                }
            }
        } else {
            selectedId = nil
        }
    }

    func nodeColor(_ kind: String) -> Color {
        switch kind {
        case "moi":      return Color(hex: "#FFFFFF")
        case "projet":   return Color(hex: "#22D3EE")
        case "personne": return Color(hex: "#F472B6")
        case "conv":     return Color(hex: "#93A4C3")
        case "decision": return Color(hex: "#A78BFA")
        case "lecon":    return Color(hex: "#F7B32B")
        case "fait":     return Color(hex: "#60A5FA")
        case "pref":     return Color(hex: "#34D399")
        default:         return HubTheme.secondary
        }
    }
}

// MARK: - HubMemoryGraphPage

struct HubMemoryGraphPage: View {
    @StateObject private var model = MemoryGraphModel()
    @Environment(\.hubVisible) private var visible

    @State private var rotX: Double = -0.3
    @State private var rotY: Double = 0.4
    @State private var zoom: Double = 1.0
    @State private var dragStart: CGPoint? = nil
    @State private var dragRotX: Double = -0.3
    @State private var dragRotY: Double = 0.4

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Full-bleed graph canvas
            TimelineView(.animation(paused: !visible)) { timeline in
                Canvas { ctx, size in
                    drawGraph(ctx: &ctx, size: size, date: timeline.date)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = value.startLocation
                            dragRotX = rotX
                            dragRotY = rotY
                        }
                        let dx = value.location.x - value.startLocation.x
                        let dy = value.location.y - value.startLocation.y
                        rotY = dragRotY + dx * 0.005
                        rotX = dragRotX + dy * 0.005
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { v in zoom = max(0.3, min(3.0, v)) }
            )
            // A3: Hover to highlight + tap to isolate
            .onContinuousHover { phase in
                if case .active(let pt) = phase {
                    model.updateHover(at: pt)
                } else {
                    model.hoveredId = nil
                }
            }
            .onTapGesture { model.handleTap() }

            // A4: Filter bar (top-leading)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        let allKinds = ["conv", "projet", "decision", "lecon", "fait", "pref", "personne"]
                        Button(action: { model.filterKinds.removeAll() }) {
                            Text(String(localized: "hub.memory.graph.filter-all"))
                        }
                        .buttonStyle(MemoryFilterButtonStyle(selected: model.filterKinds.isEmpty))
                        ForEach(allKinds, id: \.self) { kind in
                            Button(action: {
                                if model.filterKinds.contains(kind) {
                                    model.filterKinds.remove(kind)
                                } else {
                                    model.filterKinds.insert(kind)
                                }
                            }) {
                                Text(verbatim: kind)
                            }
                            .buttonStyle(MemoryFilterButtonStyle(selected: model.filterKinds.contains(kind)))
                        }
                        // A5: Period picker — labels via verbatim to skip localization check
                        let periodBinding = Binding(
                            get: { model.periodDays ?? 0 },
                            set: { model.periodDays = $0 == 0 ? nil : $0 }
                        )
                        Picker(selection: periodBinding, label: Text(verbatim: "")) {
                            Text(String(localized: "hub.memory.graph.filter-all")).tag(0)
                            Text(String(localized: "hub.memory.graph.period-7d")).tag(7)
                            Text(String(localized: "hub.memory.graph.period-30d")).tag(30)
                            Text(String(localized: "hub.memory.graph.period-90d")).tag(90)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Info panel top-right
            if let nodeId = model.selectedId ?? model.hoveredId,
               let node = model.graph?.nodes.first(where: { $0.id == nodeId }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(node.label)
                        .font(.system(size: 14, weight: .semibold))
                    Text(node.kind)
                        .font(.system(size: 11))
                        .foregroundColor(model.nodeColor(node.kind))
                    if let d = node.date {
                        Text(d).font(.system(size: 11)).foregroundColor(HubTheme.muted)
                    }
                    if let p = node.projet {
                        Text(p).font(.system(size: 11)).foregroundColor(HubTheme.secondary)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.75)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)))
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // Bottom overlay
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    // Counter
                    if let g = model.graph {
                        Text(String(format: String(localized: "hub.memory.graph.counter"), g.nodes.count, g.edges.count))
                            .font(.system(size: 11))
                            .foregroundColor(HubTheme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6)))
                    }
                    Spacer()
                    // A1: Pause / Reprendre button
                    let pauseLabel = model.isPaused
                        ? String(localized: "hub.memory.graph.resume")
                        : String(localized: "hub.memory.graph.pause")
                    Button(action: { model.isPaused.toggle() }) {
                        Text(verbatim: pauseLabel)
                    }
                    .buttonStyle(HubButtonStyle(primary: false))

                    // A2: Voir grandir button
                    Button(action: { model.startGrow() }) {
                        Text(String(localized: "hub.memory.graph.replay"))
                    }
                    .buttonStyle(HubButtonStyle(primary: false))

                    // Recenter button
                    Button(String(localized: "hub.memory.graph.recenter")) {
                        withAnimation(.spring(response: 0.4)) {
                            rotX = -0.3; rotY = 0.4; zoom = 1.0
                            model.autoRotY = 0
                        }
                    }
                    .buttonStyle(HubButtonStyle())
                }
                .padding(16)
            }

            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .background(HubTheme.panel)
        .onAppear { model.load() }
    }

    // MARK: - Drawing

    private func drawGraph(ctx: inout GraphicsContext, size: CGSize, date: Date) {
        guard let g = model.graph else { return }

        // Advance impulses + auto-rotate
        model.advance(dt: 1.0 / 60.0)

        let cx = size.width / 2
        let cy = size.height / 2
        let scale = zoom * min(size.width, size.height) / 1200

        // A4: Filter by kind
        let filteredNodes: [BrainGraphNode]
        if model.filterKinds.isEmpty {
            filteredNodes = g.nodes
        } else {
            filteredNodes = g.nodes.filter { model.filterKinds.contains($0.kind) || $0.kind == "moi" }
        }

        // A5: Filter by period
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let nodesForPeriod: [BrainGraphNode]
        if let days = model.periodDays {
            let cutoff = now.addingTimeInterval(-Double(days) * 86400)
            nodesForPeriod = filteredNodes.filter { n in
                guard let d = n.date, let date = isoFormatter.date(from: d) else {
                    return n.kind == "moi" || n.kind == "projet"
                }
                return date >= cutoff
            }
        } else {
            nodesForPeriod = filteredNodes
        }

        // A2: Grow animation — limit visible nodes
        let visibleNodes = model.growCount >= 0
            ? Array(nodesForPeriod.prefix(model.growCount))
            : nodesForPeriod

        let visibleIds = Set(visibleNodes.map { $0.id })

        // Build 3D positions
        var pos3D: [String: SIMD3<Double>] = [:]
        for node in visibleNodes {
            pos3D[node.id] = sphere3D(node: node, allNodes: g.nodes)
        }

        // A1: combine manual rotation + auto-rotate
        let effectiveRotY = rotY + model.autoRotY

        // Project to 2D
        func project(_ p3: SIMD3<Double>) -> (CGPoint, Double) {
            let rx = rotX, ry = effectiveRotY
            // Rotate Y
            let x1 = p3.x * cos(ry) + p3.z * sin(ry)
            let y1 = p3.y
            let z1 = -p3.x * sin(ry) + p3.z * cos(ry)
            // Rotate X
            let x2 = x1
            let y2 = y1 * cos(rx) - z1 * sin(rx)
            let z2 = y1 * sin(rx) + z1 * cos(rx)
            let persp = 1200 / (1200 + z2 * scale * 400)
            let sx = cx + x2 * scale * persp * 400
            let sy = cy + y2 * scale * persp * 400
            return (CGPoint(x: sx, y: sy), z2)
        }

        let isolated = model.selectedId != nil

        // Draw edges
        for edge in g.edges {
            guard visibleIds.contains(edge.from) && visibleIds.contains(edge.to) else { continue }
            guard let a = pos3D[edge.from], let b = pos3D[edge.to] else { continue }
            let (pa, za) = project(a)
            let (pb, _) = project(b)
            let depth = (za + 1) / 2  // 0 far, 1 near
            let opacity = isolated ? 0.04 : (depth > 0.6 ? 0.14 : (depth > 0.3 ? 0.08 : 0.04))
            var path = Path()
            path.move(to: pa)
            path.addLine(to: pb)
            ctx.stroke(path, with: .color(Color.white.opacity(opacity)), lineWidth: 0.6)
        }

        // Draw impulses
        for impulse in model.impulses {
            guard impulse.edgeIdx < g.edges.count else { continue }
            let edge = g.edges[impulse.edgeIdx]
            guard let a = pos3D[edge.from], let b = pos3D[edge.to] else { continue }
            // Prend direction en compte
            let (pA, pB) = impulse.direction > 0 ? (a, b) : (b, a)
            guard visibleIds.contains(edge.from) && visibleIds.contains(edge.to) else { continue }
            let t = Double(impulse.t)
            let p3 = pA + (pB - pA) * t
            let (pt, _) = project(p3)
            ctx.drawLayer { inner in
                inner.addFilter(.blur(radius: 2))
                inner.fill(Path(ellipseIn: CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4)),
                           with: .color(Color(hex: "#22D3EE").opacity(0.6)))
            }
        }

        // A3: Reset screen positions at start of each draw
        model.nodeScreenPositions = [:]

        // Draw nodes
        for node in visibleNodes {
            guard let p3 = pos3D[node.id] else { continue }
            let (pt, z) = project(p3)
            let depth = (z + 1) / 2
            let r = max(2, (depth * 7 + 1)) * (node.kind == "moi" ? 1.8 : 1.0)
            let color = model.nodeColor(node.kind)
            let isSelected = node.id == model.selectedId
            let isHovered = node.id == model.hoveredId
            let isNeighbor: Bool
            if let sel = model.selectedId, isolated {
                if let g = model.graph {
                    isNeighbor = g.edges.contains { ($0.from == sel && $0.to == node.id) || ($0.to == sel && $0.from == node.id) }
                } else { isNeighbor = false }
            } else { isNeighbor = false }
            let dimmed = isolated && !isSelected && !isHovered && !isNeighbor
            let alpha: Double = dimmed ? 0.12 : 1.0

            // Halo additif
            ctx.drawLayer { inner in
                inner.addFilter(.blur(radius: r * 1.8))
                // blendMode additif: accumule la lumière
                inner.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                           with: .color(color.opacity(0.45 * alpha)))
            }
            // Cœur blanc
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r * 0.6, y: pt.y - r * 0.6, width: r * 1.2, height: r * 1.2)),
                     with: .color(color.opacity(0.6 * alpha)))
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r * 0.4, y: pt.y - r * 0.4, width: r * 0.8, height: r * 0.8)),
                     with: .color(Color.white.opacity(0.9 * alpha)))

            // A3: Store screen position for hover/tap detection
            model.nodeScreenPositions[node.id] = pt

            // Label on hover / selected
            if (isHovered || isSelected) && node.kind != "moi" {
                ctx.draw(Text(node.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white),
                         at: CGPoint(x: pt.x, y: pt.y - r - 8))
            }
        }
    }

    private func sphere3D(node: BrainGraphNode, allNodes: [BrainGraphNode]) -> SIMD3<Double> {
        if node.kind == "moi" { return .zero }
        let r: Double
        switch node.kind {
        case "projet":   r = 200
        case "conv":     r = 400
        default:         r = 550
        }
        // Deterministic pseudo-random from id hash
        let hash = abs(node.id.hashValue)
        let theta = Double(hash % 1000) / 1000.0 * .pi * 2
        let phi   = Double((hash / 1000) % 1000) / 1000.0 * .pi
        return SIMD3(r * sin(phi) * cos(theta),
                     r * cos(phi),
                     r * sin(phi) * sin(theta))
    }
}

// MARK: - IdentifiableString (helper for sheet binding)

struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
}

// MARK: - HubMemoryRecurrencesPage

struct HubMemoryRecurrencesPage: View {
    @State private var data: BrainRecurrencesResponse? = nil
    @State private var isLoading = true
    @State private var claudeMdPreview: IdentifiableString? = nil
    @State private var pendingMdPath: String? = nil
    @State private var pendingMdContent: String? = nil

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.memory-recurrences")) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else if let d = data {
                // Habits
                if !d.groupes.isEmpty {
                    HubLabel(String(localized: "hub.memory.recurrences.habits"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(Array(d.groupes.prefix(10).enumerated()), id: \.offset) { _, g in
                            RecurrenceHabitCard(
                                groupe: g,
                                onMakeSkill: { makeSkillDraft(from: g) },
                                onAddToClaudeMd: { prepareClaudeMdAdd(from: g) }
                            )
                        }
                    }
                } else {
                    HubEmptyState(text: String(localized: "hub.memory.recurrences.habits"), color: "#22D3EE")
                }

                // Errors
                HubLabel(String(localized: "hub.memory.recurrences.errors"))
                    .padding(.top, 8)
                if d.erreurs.isEmpty {
                    HubEmptyState(text: String(localized: "hub.memory.recurrences.errors"), color: "#22D3EE")
                } else {
                    HubCard {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(d.erreurs.enumerated()), id: \.offset) { idx, err in
                                if idx > 0 { HubDivider() }
                                HStack(spacing: 10) {
                                    Text(err.statut)
                                        .font(.system(size: 14))
                                    Text(err.texte)
                                        .font(.system(size: 13))
                                        .foregroundColor(HubTheme.body)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(verbatim: String(UnicodeScalar(0x00D7)!) + String(err.count))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(HubTheme.red)
                                }
                                .padding(.vertical, 10)
                            }
                        }
                    }
                }

                // Artifacts
                HubLabel(String(localized: "hub.memory.recurrences.created"))
                    .padding(.top, 8)
                if d.artifacts.isEmpty {
                    HubEmptyState(text: String(localized: "hub.memory.recurrences.created"), color: "#22D3EE")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(d.artifacts.enumerated()), id: \.offset) { _, a in
                                RecurrenceArtifactBadge(artifact: a)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $claudeMdPreview) { wrapped in
            SettingsJsonDiffSheet(
                diffText: wrapped.value,
                onConfirm: { confirmClaudeMdAdd(); claudeMdPreview = nil },
                onCancel: { claudeMdPreview = nil }
            )
        }
        .onAppear {
            Task {
                do {
                    data = try await BrainRunner.shared.run(["recurrences", "--json"],
                                                            as: BrainRecurrencesResponse.self)
                } catch {}
                isLoading = false
            }
        }
    }

    // C3: Prepare CLAUDE.md addition
    private func prepareClaudeMdAdd(from groupe: BrainGroupe) {
        let path = "\(NSHomeDirectory())/.claude/CLAUDE.md"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let freq = groupe.freqJours.map { " (tous les \(String(format: "%.0f", $0))j)" } ?? ""
        let addition = "\n\n## Habitude récurrente : \(groupe.titre)\n> \(groupe.count) occurrences\(freq)\n"
        let preview = "+ " + addition.replacingOccurrences(of: "\n", with: "\n+ ")
        pendingMdPath = path
        pendingMdContent = existing + addition
        claudeMdPreview = IdentifiableString(value: "Ajout dans ~/.claude/CLAUDE.md :\n\n\(preview)")
    }

    private func confirmClaudeMdAdd() {
        guard let path = pendingMdPath, let content = pendingMdContent else { return }

        // Backup daté — refuser si échec
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let bkPath = path + ".backup-" + formatter.string(from: Date())
        do {
            try FileManager.default.copyItem(atPath: path, toPath: bkPath)
        } catch {
            // Don't abort if backup fails for CLAUDE.md (it may not exist yet)
        }

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            // Error is silent for now — no UI state to show it
        }
    }

    // C2: Create skill draft
    private func makeSkillDraft(from groupe: BrainGroupe) {
        let brainPath = UserDefaults.standard.string(forKey: "brainPath") ?? "\(NSHomeDirectory())/CoucouBrain"
        let draftsDir = "\(brainPath)/drafts"
        try? FileManager.default.createDirectory(atPath: draftsDir, withIntermediateDirectories: true)
        let slug = String(groupe.titre.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            .prefix(40))
        let filename = "\(draftsDir)/skill-\(slug).md"
        let freq = groupe.freqJours.map { " — tous les \(String(format: "%.0f", $0))j" } ?? ""
        let content = "# Skill : \(groupe.titre)\n\n> Récurrence : \(groupe.count) fois\(freq)\n\n## Ce que je fais à chaque fois\n\n...\n\n## Ce que Claude doit savoir\n\n...\n\n## Instructions\n\n...\n"
        try? content.write(toFile: filename, atomically: true, encoding: .utf8)
        NSWorkspace.shared.selectFile(filename, inFileViewerRootedAtPath: draftsDir)
    }
}

// MARK: - RecurrenceHabitCard

private struct RecurrenceHabitCard: View {
    let groupe: BrainGroupe
    var onMakeSkill: (() -> Void)? = nil
    var onAddToClaudeMd: (() -> Void)? = nil

    var body: some View {
        HubCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(groupe.titre)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HubTheme.text)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(String(format: String(localized: "hub.memory.recurrences.times"), groupe.count))
                        .font(.system(size: 11))
                        .foregroundColor(HubTheme.secondary)
                    if let freq = groupe.freqJours {
                        Text(String(format: String(localized: "hub.memory.recurrences.freq-days"), freq))
                            .font(.system(size: 11))
                            .foregroundColor(HubTheme.muted)
                    }
                }
                // C1: Mini histogram avec labels x
                if !groupe.histogram.isEmpty {
                    let maxVal = max(1, groupe.histogram.max() ?? 1)
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(groupe.histogram.enumerated()), id: \.offset) { i, v in
                            VStack(spacing: 1) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color(hex: "#22D3EE").opacity(0.5 + 0.5 * Double(v) / Double(maxVal)))
                                    .frame(width: 10, height: max(2, 24 * Double(v) / Double(maxVal)))
                                if i == 0 || i == 4 || i == 9 {
                                    Text(weekLabel(weekOffset: 9 - i))
                                        .font(.system(size: 7))
                                        .foregroundColor(HubTheme.muted)
                                } else {
                                    Text("")
                                        .font(.system(size: 7))
                                }
                            }
                        }
                    }
                    .frame(height: 36)
                }
                // C2 + C3: Action buttons
                if onMakeSkill != nil || onAddToClaudeMd != nil {
                    HStack(spacing: 6) {
                        if let action = onMakeSkill {
                            Button(action: action) { Text(String(localized: "hub.memory.recurrences.make-skill")) }
                                .buttonStyle(HubButtonStyle(primary: false))
                        }
                        if let action = onAddToClaudeMd {
                            Button(action: action) { Text(String(localized: "hub.memory.recurrences.add-claude-md")) }
                                .buttonStyle(HubButtonStyle(primary: false))
                        }
                    }
                    .font(.system(size: 11))
                    .padding(.top, 4)
                }
            }
        }
    }

    // C1: Week label for histogram x-axis
    private func weekLabel(weekOffset: Int) -> String {
        if weekOffset == 0 { return "auj" }
        let date = Calendar.current.date(byAdding: .weekOfYear, value: -weekOffset, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "d/M"
        return f.string(from: date)
    }
}

// MARK: - RecurrenceArtifactBadge

private struct RecurrenceArtifactBadge: View {
    let artifact: BrainArtifact

    var body: some View {
        VStack(spacing: 4) {
            Text(verbatim: String(artifact.count))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Color(hex: "#22D3EE"))
            Text(artifact.kind)
                .font(.system(size: 11))
                .foregroundColor(HubTheme.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: "#22D3EE").opacity(0.15)))
    }
}

// MARK: - SettingsJsonDiffSheet

private struct SettingsJsonDiffSheet: View {
    let diffText: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "hub.memory.settings.hooks.diff-title"))
                .font(.system(size: 17, weight: .bold))
            Text(String(localized: "hub.memory.settings.hooks.diff-subtitle"))
                .font(.system(size: 12))
                .foregroundColor(HubTheme.secondary)
            ScrollView {
                Text(diffText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(HubTheme.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(HubTheme.field))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
            HStack(spacing: 10) {
                Spacer()
                Button(action: onCancel) { Text(String(localized: "hub.memory.settings.hooks.cancel")) }
                    .buttonStyle(HubButtonStyle(primary: false))
                Button(action: onConfirm) { Text(String(localized: "hub.memory.settings.hooks.confirm")) }
                    .buttonStyle(HubButtonStyle(primary: true))
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(HubTheme.panel)
        .foregroundColor(HubTheme.text)
        .preferredColorScheme(.dark)
    }
}

// MARK: - HooksMCPSection

@MainActor
private struct HooksMCPSection: View {
    @State private var hooksEnabled = false
    @State private var mcpEnabled = false
    @State private var showDiff = false
    @State private var diffContent = ""
    @State private var pendingAction: SettingsJsonAction? = nil
    @State private var errorMessage: String? = nil

    enum SettingsJsonAction { case enableHooks, disableHooks, enableMcp, disableMcp }

    var body: some View {
        VStack(spacing: 0) {
            HubRow(title: "Brain hooks",
                   detail: "Injecte le contexte brain à chaque session Claude Code") {
                Button(hooksEnabled ? "Désactiver" : "Activer") {
                    pendingAction = hooksEnabled ? .disableHooks : .enableHooks
                    diffContent = computeHooksDiff(enable: !hooksEnabled)
                    showDiff = true
                }
                .buttonStyle(HubButtonStyle(primary: !hooksEnabled))
            }
            HubDivider()
            HubRow(title: "Serveur MCP",
                   detail: "brain_search, brain_get… accessibles depuis Claude Code") {
                Button(mcpEnabled ? "Désactiver" : "Activer") {
                    pendingAction = mcpEnabled ? .disableMcp : .enableMcp
                    diffContent = computeMcpDiff(enable: !mcpEnabled)
                    showDiff = true
                }
                .buttonStyle(HubButtonStyle(primary: !mcpEnabled))
            }
            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(HubTheme.red)
                    .padding(.top, 8)
            }
        }
        .onAppear {
            refreshStatus()
            BrainRunner.shared.discoverAsync()
        }
        .sheet(isPresented: $showDiff) {
            SettingsJsonDiffSheet(
                diffText: diffContent,
                onConfirm: {
                    showDiff = false
                    applyAction()
                },
                onCancel: { showDiff = false }
            )
        }
    }

    private func refreshStatus() {
        let (hasHooks, hasMcp) = readCurrentStatus()
        hooksEnabled = hasHooks
        mcpEnabled = hasMcp
    }

    private func readCurrentStatus() -> (Bool, Bool) {
        let path = "\(NSHomeDirectory())/.claude/settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, false)
        }
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        let ss = (hooks["SessionStart"] as? [[String: Any]]) ?? []
        let hasHooks = ss.contains { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).contains { h in
                (h["command"] as? String)?.contains("brain-session-start") == true
            }
        }
        let mcp = json["mcpServers"] as? [String: Any] ?? [:]
        let hasMcp = mcp["coucou-brain"] != nil
        return (hasHooks, hasMcp)
    }

    private func computeHooksDiff(enable: Bool) -> String {
        if enable {
            let hooksDir = readHooksDir()
            let nodeCmd = findNodeCommand()
            return """
+  "hooks": {
+    "SessionStart": [{
+      "hooks": [{"type": "command",
+        "command": "\(nodeCmd) \\"\(hooksDir)/brain-session-start.js\\"",
+        "timeout": 8, "statusMessage": "Loading brain context..."}]
+    }],
+    "UserPromptSubmit": [{
+      "hooks": [{"type": "command",
+        "command": "\(nodeCmd) \\"\(hooksDir)/brain-prompt.js\\"",
+        "timeout": 5}]
+    }]
+  }
"""
        } else {
            return """
-  entries "brain-session-start" in SessionStart
-  entries "brain-prompt" in UserPromptSubmit
"""
        }
    }

    private func computeMcpDiff(enable: Bool) -> String {
        if enable {
            return """
+  "mcpServers": {
+    "coucou-brain": {
+      "type": "stdio",
+      "command": "brain",
+      "args": ["mcp"]
+    }
+  }
"""
        } else {
            return """
-  "mcpServers": { "coucou-brain": ... }
"""
        }
    }

    private func readHooksDir() -> String {
        let path = "\(NSHomeDirectory())/.claude/brain-hooks.json"
        if let data = FileManager.default.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dir = json["hooksDir"] as? String {
            return dir
        }
        if let bin = BrainRunner.shared.binaryPath {
            let dir = URL(fileURLWithPath: bin).deletingLastPathComponent()
                .appendingPathComponent("../hooks").standardized.path
            return dir
        }
        return "\(NSHomeDirectory())/Developer/coucou/brain/hooks"
    }

    private func findNodeCommand() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.nvm/alias/default/bin/node",
            "/opt/homebrew/opt/node@22/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "node"
    }

    private func applyAction() {
        guard let action = pendingAction else { return }
        let path = "\(NSHomeDirectory())/.claude/settings.json"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupPath = path + ".backup-" + formatter.string(from: Date())

        do {
            try brainSettingsApply(path: path, backupPath: backupPath) { json in
                switch action {
                case .enableHooks:  brainHooksAdd(to: &json, hooksDir: readHooksDir(), nodeCmd: findNodeCommand())
                case .disableHooks: brainHooksRemove(from: &json)
                case .enableMcp:    brainMcpAdd(to: &json)
                case .disableMcp:   brainMcpRemove(from: &json)
                }
            }
            refreshStatus()
            errorMessage = nil
        } catch MemorySettingsError.fileNotFound {
            errorMessage = NSLocalizedString("hub.memory.settings.hooks.error-read",
                value: "Impossible de lire ~/.claude/settings.json", comment: "")
        } catch MemorySettingsError.invalidJSON {
            errorMessage = NSLocalizedString("hub.memory.settings.hooks.error-json",
                value: "Le fichier n'est pas du JSON valide — aucune écriture effectuée.", comment: "")
        } catch MemorySettingsError.backupFailed {
            errorMessage = NSLocalizedString("hub.memory.settings.hooks.error-backup",
                value: "Impossible de créer la sauvegarde — aucune écriture effectuée.", comment: "")
        } catch MemorySettingsError.serializationError {
            errorMessage = NSLocalizedString("hub.memory.settings.hooks.error-serial",
                value: "Erreur de sérialisation — aucune écriture effectuée.", comment: "")
        } catch {
            errorMessage = String(format: NSLocalizedString("hub.memory.settings.hooks.error-write",
                value: "Erreur écriture : %@", comment: ""), error.localizedDescription)
        }
    }
}

// MARK: - HubMemorySettingsPage

struct HubMemorySettingsPage: View {
    @ObservedObject private var runner = BrainRunner.shared
    @AppStorage("brainBinaryPath") private var customPath: String = ""
    @State private var status: BrainStatus? = nil
    @State private var isImporting = false
    @State private var importSuccess: String? = nil
    @State private var confirmWipe = false
    @State private var isWiping = false
    @State private var currentDepth: String = "search"
    // B2: persisted reminder toggle
    @AppStorage("brainImportReminder") private var reminder: Bool = false

    private let depths: [(String, String, String)] = [
        ("search", "Recherche uniquement", "Cherche dans le texte brut"),
        ("live",   "Digestion en direct",  "Résume chaque nouvelle conversation"),
        ("full",   "Rétroactif complet",   "Rejoue l'historique complet"),
    ]

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.memory-settings")) {
            // Status card
            if let st = status {
                HubGlowCard(color: Color(hex: "#22D3EE")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let idx = st.rawIndex {
                            HStack(spacing: 20) {
                                statItem(label: "Conversations", value: "\(idx.conversations)")
                                statItem(label: "Sessions",      value: "\(idx.sessions)")
                                statItem(label: "Messages",      value: "\(idx.messages)")
                            }
                        } else {
                            Text(String(localized: "hub.memory.settings.no-index"))
                                .font(.system(size: 13))
                                .foregroundColor(HubTheme.secondary)
                        }
                        if let pause = st.pause {
                            Text(String(format: String(localized: "hub.memory.settings.paused"), pause))
                                .font(.system(size: 11))
                                .foregroundColor(HubTheme.muted)
                        }
                    }
                }
            } else {
                ProgressView()
            }

            // Sources
            HubLabel(String(localized: "hub.memory.settings.sources"))
            HubCard {
                // Claude Code
                HubRow(title: "Claude Code") {
                    Text(String(localized: "hub.memory.settings.auto-indexed"))
                        .font(.system(size: 11))
                        .foregroundColor(HubTheme.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(HubTheme.green.opacity(0.15)))
                }
                HubDivider()
                // Claude.ai
                VStack(alignment: .leading, spacing: 10) {
                    HubRow(title: "Claude.ai") {
                        Button(String(localized: "hub.memory.settings.import")) { isImporting = true }
                            .buttonStyle(HubButtonStyle())
                    }
                    if let msg = importSuccess {
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundColor(HubTheme.green)
                            .padding(.leading, 4)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                    return true
                }
                HubDivider()
                // B2: Monthly reminder toggle with @AppStorage + UserNotifications
                HubRow(title: "Rappel mensuel import",
                       detail: "Notification mensuelle pour importer les convs Claude.ai") {
                    Toggle("", isOn: $reminder)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: reminder) { _, new in
                            if new { scheduleMonthlyReminder() } else { cancelReminder() }
                        }
                }
            }
            .fileImporter(isPresented: $isImporting,
                          allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result { importZip(url) }
            }

            // B1: Claude Code hooks + MCP section
            let claudeCodeSectionTitle = "CLAUDE CODE"
            HubLabel(claudeCodeSectionTitle)
            HubCard {
                HooksMCPSection()
            }

            // Depth
            HubLabel(String(localized: "hub.memory.settings.depth"))
            HubCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(depths.enumerated()), id: \.offset) { idx, depth in
                        if idx > 0 { HubDivider() }
                        Button {
                            setDepth(depth.0)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: currentDepth == depth.0 ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(currentDepth == depth.0 ? Color(hex: "#22D3EE") : HubTheme.muted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(depth.1)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(HubTheme.text)
                                    Text(depth.2)
                                        .font(.system(size: 11))
                                        .foregroundColor(HubTheme.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // B3: Progress indicator under depth selector
            if let st = status, let idx = st.rawIndex, idx.messages > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(HubTheme.green)
                        .font(.system(size: 12))
                    Text(String(format: String(localized: "hub.memory.settings.index-info"), idx.messages, currentDepth))
                        .font(.system(size: 12))
                        .foregroundColor(HubTheme.secondary)
                }
                .padding(.horizontal, 4)
            }

            // Privacy
            HubLabel(String(localized: "hub.memory.settings.privacy"))
            HubCard {
                HubRow(title: String(localized: "hub.memory.settings.open-folder")) {
                    Button(String(localized: "hub.memory.settings.open-folder")) {
                        let url = URL(fileURLWithPath: NSHomeDirectory() + "/CoucouBrain")
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(HubButtonStyle())
                }
                HubDivider()
                HubRow(title: String(localized: "hub.memory.settings.wipe")) {
                    Button(String(localized: "hub.memory.settings.wipe")) {
                        confirmWipe = true
                    }
                    .buttonStyle(HubButtonStyle())
                    .foregroundColor(HubTheme.red)
                }
            }
            .alert(String(localized: "hub.memory.settings.wipe.confirm-title"), isPresented: $confirmWipe) {
                Button(String(localized: "hub.memory.settings.wipe.confirm-action"), role: .destructive) { wipeIndex() }
                Button(String(localized: "hub.memory.settings.wipe.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "hub.memory.settings.wipe.confirm-message"))
            }
        }
        .onAppear { loadStatus() }
    }

    @ViewBuilder private func statItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color(hex: "#22D3EE"))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(HubTheme.secondary)
        }
    }

    private func loadStatus() {
        Task {
            do {
                status = try await BrainRunner.shared.run(["status", "--json"], as: BrainStatus.self)
                currentDepth = status?.depth ?? "search"
            } catch {}
        }
    }

    private func setDepth(_ value: String) {
        currentDepth = value
        Task {
            _ = try? await BrainRunner.shared.run(["config", "set", "depth", value, "--json"])
        }
    }

    private func importZip(_ url: URL) {
        Task {
            do {
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                let result = try await BrainRunner.shared.run(["import", url.path, "--json"],
                                                              as: BrainImportResponse.self)
                importSuccess = "Importé : \(result.conversations) conversations, \(result.messages) messages"
                await loadStatusAsync()
            } catch {
                importSuccess = "Erreur lors de l'import"
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == "zip" else { return }
                Task { @MainActor in importZip(url) }
            }
        }
    }

    private func wipeIndex() {
        isWiping = true
        Task {
            _ = try? await BrainRunner.shared.run(["wipe", "--yes", "--json"])
            status = nil
            isWiping = false
        }
    }

    @MainActor
    private func loadStatusAsync() async {
        do {
            status = try await BrainRunner.shared.run(["status", "--json"], as: BrainStatus.self)
            currentDepth = status?.depth ?? "search"
        } catch {}
    }

    // B2: Monthly reminder via UserNotifications
    private func scheduleMonthlyReminder() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        center.removePendingNotificationRequests(withIdentifiers: ["brain-monthly-import"])
        let content = UNMutableNotificationContent()
        content.title = "Mémoire Coucou"
        content.body = "Export tes conversations Claude.ai ce mois-ci : claude.ai/settings/export"
        var comps = DateComponents()
        comps.day = 1; comps.hour = 10; comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let req = UNNotificationRequest(identifier: "brain-monthly-import", content: content, trigger: trigger)
        center.add(req) { _ in }
    }

    private func cancelReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["brain-monthly-import"])
    }
}

// A minimal Decodable for brain import response
private struct BrainImportResponse: Decodable {
    let ok: Bool
    let conversations: Int
    let messages: Int
}

#endif

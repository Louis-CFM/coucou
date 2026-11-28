#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - BrainRunner

@MainActor
final class BrainRunner: ObservableObject {
    static let shared = BrainRunner()

    @AppStorage("brainBinaryPath") var customPath: String = ""

    var binaryPath: String? {
        // 1. User-provided custom path
        if !customPath.isEmpty {
            if FileManager.default.isExecutableFile(atPath: customPath) { return customPath }
        }
        // 2. Well-known locations
        let candidates = [
            "\(NSHomeDirectory())/.nvm/alias/default/bin/brain",
            "\(NSHomeDirectory())/.nvm/versions/node/\(nvmDefaultVersion() ?? "")/bin/brain",
            "/usr/local/bin/brain",
            "/opt/homebrew/bin/brain",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // 3. Shell which
        if let found = discoverViashell() { return found }
        return nil
    }

    var isInstalled: Bool { binaryPath != nil }

    // Run brain <args> and return stdout as Data. Throws on non-zero exit.
    func run(_ args: [String]) async throws -> Data {
        guard let bin = binaryPath else {
            throw BrainError.notInstalled
        }
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

    // MARK: - Private helpers

    private func nvmDefaultVersion() -> String? {
        let p = "\(NSHomeDirectory())/.nvm/alias/default"
        return try? String(contentsOfFile: p, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func discoverViashell() -> String? {
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
                                            selected: model.selected?.id == result.id)
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
                            Text("+ \(d.messages.count - 8) messages…")
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
                    }
                }
            }
            .padding(18)
        }
        .background(HubTheme.panel)
    }
}

// MARK: - MemoryResultRow

private struct MemoryResultRow: View {
    let result: BrainSearchResult
    let selected: Bool
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
                        Text(result.extrait)
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
    @Published var impulses: [GraphImpulse] = []

    struct GraphImpulse {
        var edgeIdx: Int
        var t: Float
        var speed: Float
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
                                 speed: Float.random(in: 0.001...0.004))
                }
            } catch {}
            isLoading = false
        }
    }

    func advance(dt: Double) {
        guard let g = graph, !g.edges.isEmpty else { return }
        for i in impulses.indices {
            impulses[i].t += Float(dt) * impulses[i].speed * 60
            if impulses[i].t > 1 {
                impulses[i].t = 0
                impulses[i].edgeIdx = Int.random(in: 0..<g.edges.count)
                impulses[i].speed = Float.random(in: 0.001...0.004)
            }
        }
    }

    func nodeColor(_ kind: String) -> Color {
        switch kind {
        case "moi":      return Color(hex: "#22D3EE")
        case "projet":   return Color(hex: "#FB923C")
        case "conv":     return Color(hex: "#3B9EFF")
        case "decision": return Color(hex: "#A78BFA")
        case "lecon":    return Color(hex: "#34D399")
        case "fait":     return Color(hex: "#F7B32B")
        case "pref":     return Color(hex: "#F472B6")
        case "personne": return Color(hex: "#8E939C")
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
            .onContinuousHover { phase in
                // hover handled via geometry in canvas
                _ = phase
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
                        Text("\(g.nodes.count) nœuds · \(g.edges.count) liens")
                            .font(.system(size: 11))
                            .foregroundColor(HubTheme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6)))
                    }
                    Spacer()
                    // Recenter button
                    Button(String(localized: "hub.memory.graph.recenter")) {
                        withAnimation(.spring(response: 0.4)) {
                            rotX = -0.3; rotY = 0.4; zoom = 1.0
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

        // Advance impulses
        model.advance(dt: 1.0 / 60.0)

        let cx = size.width / 2
        let cy = size.height / 2
        let scale = zoom * min(size.width, size.height) / 1200

        // Build 3D positions
        var pos3D: [String: SIMD3<Double>] = [:]
        for node in g.nodes {
            pos3D[node.id] = sphere3D(node: node, allNodes: g.nodes)
        }

        // Project to 2D
        func project(_ p3: SIMD3<Double>) -> (CGPoint, Double) {
            let rx = rotX, ry = rotY
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
            let t = Double(impulse.t)
            let p3 = a + (b - a) * t
            let (pt, _) = project(p3)
            ctx.drawLayer { inner in
                inner.addFilter(.blur(radius: 2))
                inner.fill(Path(ellipseIn: CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4)),
                           with: .color(Color(hex: "#22D3EE").opacity(0.6)))
            }
        }

        // Draw nodes
        for node in g.nodes {
            guard let p3 = pos3D[node.id] else { continue }
            let (pt, z) = project(p3)
            let depth = (z + 1) / 2
            let r = max(2, (depth * 7 + 1)) * (node.kind == "moi" ? 1.8 : 1.0)
            let color = model.nodeColor(node.kind)
            let isSelected = node.id == model.selectedId
            let isHovered = node.id == model.hoveredId
            let dimmed = isolated && !isSelected && !isHovered
            let alpha: Double = dimmed ? 0.2 : 1.0

            // Glow
            ctx.drawLayer { inner in
                inner.addFilter(.blur(radius: r * 1.5))
                inner.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                           with: .color(color.opacity(0.5 * alpha)))
            }
            // Core dot
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r * 0.5, y: pt.y - r * 0.5, width: r, height: r)),
                     with: .color(color.opacity(alpha)))

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

// MARK: - HubMemoryRecurrencesPage

struct HubMemoryRecurrencesPage: View {
    @State private var data: BrainRecurrencesResponse? = nil
    @State private var isLoading = true

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
                            RecurrenceHabitCard(groupe: g)
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
                                    Text("×\(err.count)")
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
}

// MARK: - RecurrenceHabitCard

private struct RecurrenceHabitCard: View {
    let groupe: BrainGroupe

    var body: some View {
        HubCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(groupe.titre)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HubTheme.text)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(groupe.count) fois")
                        .font(.system(size: 11))
                        .foregroundColor(HubTheme.secondary)
                    if let freq = groupe.freqJours {
                        Text("· tous les \(String(format: "%.1f", freq))j")
                            .font(.system(size: 11))
                            .foregroundColor(HubTheme.muted)
                    }
                }
                // Mini histogram
                if !groupe.histogram.isEmpty {
                    let maxVal = groupe.histogram.max() ?? 1
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(groupe.histogram.enumerated()), id: \.offset) { _, v in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color(hex: "#22D3EE").opacity(0.5 + 0.5 * Double(v) / Double(max(1, maxVal))))
                                .frame(width: 10, height: max(2, 24 * Double(v) / Double(max(1, maxVal))))
                        }
                    }
                    .frame(height: 24)
                }
            }
        }
    }
}

// MARK: - RecurrenceArtifactBadge

private struct RecurrenceArtifactBadge: View {
    let artifact: BrainArtifact

    var body: some View {
        VStack(spacing: 4) {
            Text("\(artifact.count)")
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
    @State private var reminder = false

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
                            Text("En pause : \(pause)")
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
                HubRow(title: String(localized: "hub.memory.settings.import") + " (rappel mensuel)") {
                    Toggle("", isOn: $reminder).toggleStyle(.switch).labelsHidden()
                }
            }
            .fileImporter(isPresented: $isImporting,
                          allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result { importZip(url) }
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
}

// A minimal Decodable for brain import response
private struct BrainImportResponse: Decodable {
    let ok: Bool
    let conversations: Int
    let messages: Int
}

#endif

#if !APPSTORE
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - LocalModelStatus
// Exposed outside the FoundationModels guard so SettingsView can reference it on macOS 15.
enum LocalModelStatus {
    case available
    case notMacOS26         // running on macOS < 26 or device not eligible
    case appleIntelligenceOff
}

// MARK: - BrainResult

struct BrainResult {
    let intents: [VoiceIntent]  // tool-derived intents (may be empty)
    let text: String            // natural-language reply to speak / display
}

// MARK: - VoiceBrain
//
// macOS 26 + Apple Intelligence: uses a LanguageModelSession per conversation.
// On macOS < 26 or when Apple Intelligence is off, every call returns nil immediately
// and the caller falls back to IntentParser + ConversationContext.
//
// Thread: @MainActor throughout.
@MainActor
final class VoiceBrain {
    static let shared = VoiceBrain()

    /// Current model availability status, updated lazily.
    private(set) var modelStatus: LocalModelStatus

    /// Opaque session container — avoids @available on stored property.
    private var sessionBox: AnyObject? = nil

    private init() {
        modelStatus = VoiceBrain._checkStatus()
    }

    // MARK: - Conversation lifecycle

    func beginConversation() {
        sessionBox = VoiceBrain._makeSession()
    }

    func endConversation() {
        sessionBox = nil
    }

    // MARK: - Intent resolution

    /// Try to resolve `transcript` using the language model.
    /// Returns nil if the model is unavailable or if the model cannot map to any intent.
    func resolve(_ transcript: String, pills: [PillDefinition]) async -> BrainResult? {
        // Lazily create session on first call so the model is available
        // even for the very first turn (before speakAndContinueConversation fires).
        if sessionBox == nil { sessionBox = VoiceBrain._makeSession() }
        return await VoiceBrain._resolve(transcript, pills: pills, sessionBox: sessionBox)
    }

    // MARK: - Static impl helpers

    static func _checkStatus() -> LocalModelStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return .appleIntelligenceOff
                default:
                    return .notMacOS26
                }
            @unknown default:
                return .notMacOS26
            }
        }
        #endif
        return .notMacOS26
    }

    static func _makeSession() -> AnyObject? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { return nil }
            let collector = IntentCollector()
            let session = LanguageModelSession(
                tools: [PillTool(collector: collector),
                        MusicTool(collector: collector),
                        StatusTool(collector: collector)],
                instructions: """
                Tu es Coucou, un assistant dans le notch du MacBook.
                Réponds toujours dans la langue de l'utilisateur.
                Réponds avec une phrase courte et directe.
                Utilise les outils disponibles pour exécuter des commandes sur les pills et la musique.
                Pour les noms de pilules, utilise le nom exact fourni par l'utilisateur.
                """
            )
            return SessionContainer(session: session, collector: collector)
        }
        #endif
        return nil
    }

    static func _resolve(_ transcript: String,
                         pills: [PillDefinition],
                         sessionBox: AnyObject?) async -> BrainResult? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { return nil }
            guard let container = sessionBox as? SessionContainer else { return nil }
            let collector = container.collector
            collector.reset()

            // All pill names — no prefix limit; no IDs (tool resolves names via EntityResolver)
            let pillNames = pills.map { $0.name }.joined(separator: ", ")
            let prompt = """
                User said: "\(transcript)"
                Available pill names: \(pillNames)
                Use a tool if this is a command. Otherwise answer naturally in the user's language.
                """

            do {
                // Extract .content (String, Sendable) inside the task to avoid
                // LanguageModelSession.Response<String>: not Sendable.
                let text = try await withBrainTimeout(seconds: 4) {
                    let response = try await container.session.respond(to: prompt)
                    return response.content
                }
                return BrainResult(intents: collector.intents, text: text)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}

// MARK: - Timeout helper (file-private)

private func withBrainTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}

// MARK: - FoundationModels types (macOS 26 only)

#if canImport(FoundationModels)

// MARK: IntentCollector

@available(macOS 26, *)
final class IntentCollector: @unchecked Sendable {
    private(set) var intents: [VoiceIntent] = []

    func append(_ intent: VoiceIntent) { intents.append(intent) }
    func reset() { intents = [] }
}

// MARK: SessionContainer

@available(macOS 26, *)
final class SessionContainer: @unchecked Sendable {
    let session: LanguageModelSession
    let collector: IntentCollector
    init(session: LanguageModelSession, collector: IntentCollector) {
        self.session   = session
        self.collector = collector
    }
}

// MARK: PillTool

@available(macOS 26, *)
struct PillTool: Tool, @unchecked Sendable {
    let name        = "pill"
    let description = "Add, remove, set as main, or list pills in the notch. Use the pill name the user said."

    @Generable
    struct Arguments {
        @Guide(description: "Action: add | remove | setMain | list")
        var action: String
        @Guide(description: "Pill name as the user said it, e.g. GitHub, Cursor, n8n. Empty for list.")
        var pillName: String
    }

    let collector: IntentCollector

    func call(arguments: Arguments) async throws -> String {
        if arguments.action == "list" {
            let active = await MainActor.run { () -> String in
                let s = AppState.shared
                let ids = s.activeIntegrations.union([s.mainPillId])
                let names = ids.compactMap { PillCatalog.definition(for: $0)?.name }.sorted()
                return names.isEmpty ? "none" : names.joined(separator: ", ")
            }
            return "Active pills: \(active)"
        }

        let id = await MainActor.run {
            EntityResolver.resolve(arguments.pillName, from: PillCatalog.available)
        }
        guard let pillId = id else {
            return "unknown pill: \(arguments.pillName)"
        }
        let intent: VoiceIntent? = switch arguments.action {
        case "add":     .pillAdd(id: pillId)
        case "remove":  .pillRemove(id: pillId)
        case "setMain": .pillSetMain(id: pillId)
        default:        nil
        }
        if let i = intent { collector.append(i) }
        return "\(arguments.action) \(pillId)"
    }
}

// MARK: MusicTool

@available(macOS 26, *)
struct MusicTool: Tool, @unchecked Sendable {
    let name        = "music"
    let description = "Control music playback: play, pause, next, previous, volumeUp, volumeDown, search, playlist"

    @Generable
    struct Arguments {
        @Guide(description: "Action: play | pause | next | prev | volumeUp | volumeDown | search | playlist")
        var action: String
        @Guide(description: "Track or playlist name for search/playlist. Empty for other actions.")
        var query: String
    }

    let collector: IntentCollector

    func call(arguments: Arguments) async throws -> String {
        let intent: VoiceIntent? = switch arguments.action {
        case "play":       .musicPlay(target: nil)
        case "pause":      .musicPause
        case "next":       .musicNext
        case "prev":       .musicPrevious
        case "volumeUp":   .musicVolumeUp
        case "volumeDown": .musicVolumeDown
        case "search":     arguments.query.isEmpty ? nil : .musicPlaySearch(name: arguments.query)
        case "playlist":   arguments.query.isEmpty ? nil : .musicPlayPlaylist(name: arguments.query)
        default:           nil
        }
        if let i = intent { collector.append(i) }
        return "music \(arguments.action)"
    }
}

// MARK: StatusTool

@available(macOS 26, *)
struct StatusTool: Tool, @unchecked Sendable {
    let name        = "status"
    let description = "Report Coucou status: active pills, current agent sessions, music now playing"

    @Generable
    struct Arguments {
        @Guide(description: "What to report: pills | sessions | music | all")
        var query: String
    }

    let collector: IntentCollector

    func call(arguments: Arguments) async throws -> String {
        let info = await MainActor.run { () -> String in
            let s = AppState.shared
            var parts: [String] = []

            // Main pill + active integrations
            let mainName = PillCatalog.definition(for: s.mainPillId)?.name ?? s.mainPillId
            let activeNames = s.activeIntegrations
                .compactMap { PillCatalog.definition(for: $0)?.name }
                .sorted()
            let allActive = ([mainName] + activeNames).joined(separator: ", ")
            parts.append("Main pill: \(mainName). Active: \(allActive)")

            // Agent sessions
            let running = s.tasks.filter { $0.state != .idle }
            if !running.isEmpty {
                let sessionStr = running
                    .map { "\($0.name) (\($0.state.rawValue))" }
                    .joined(separator: ", ")
                parts.append("Sessions: \(sessionStr)")
            } else {
                parts.append("No active sessions")
            }

            // Music
            if s.musicPlaying, let title = MusicController.shared.trackTitle {
                parts.append("Now playing: \(title)")
            }

            return parts.joined(separator: ". ")
        }
        return info
    }
}

#endif // canImport(FoundationModels)
#endif // !APPSTORE

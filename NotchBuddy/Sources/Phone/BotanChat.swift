import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Botan chat
//
// Ask Botan about your agents, services and OKs. Apple's model answers on this iPhone
// (iOS 26+, Apple Intelligence on): nothing leaves the phone, nothing is paid. The model
// can only read what this iPhone already has, through the tools below (agents now, the
// journal, the services, the last turn of each agent); it can't approve or run anything.

struct ChatMessage: Identifiable, Equatable {
    enum Role { case you, botan }
    let id = UUID()
    let role: Role
    var text: String
    var failed = false
}

@MainActor
@Observable
final class BotanChat {
    static let shared = BotanChat()

    private(set) var messages: [ChatMessage] = []
    private(set) var answering = false

    /// Kept as `AnyObject` so the app still runs on iOS 18 (the model needs iOS 26).
    @ObservationIgnored private var session: AnyObject?

    /// Why the model can't answer here, or nil when it can.
    var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in Settings to talk with Botan. It runs on your iPhone, for free."
            case .unavailable(.modelNotReady):
                return "Apple's model is still downloading. Try again in a few minutes."
            case .unavailable(.deviceNotEligible):
                return "This iPhone can't run Apple's model."
            case .unavailable:
                return "Apple's model isn't available right now."
            }
        }
        return "Botan's chat needs iOS 26 or later."
        #else
        return "Botan's chat needs iOS 26 or later."
        #endif
    }

    func reset() {
        messages = []
        session = nil
    }

    func send(_ text: String) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answering else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.18)) {
            messages.append(ChatMessage(role: .you, text: question))
            messages.append(ChatMessage(role: .botan, text: ""))
        }
        let index = messages.count - 1
        answering = true
        defer { answering = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            await answer(question, into: index)
            return
        }
        #endif
        fail(index, unavailableReason ?? "Botan can't answer here.")
    }

    private func fail(_ index: Int, _ text: String) {
        guard messages.indices.contains(index) else { return }
        messages[index].text = text
        messages[index].failed = true
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func answer(_ question: String, into index: Int) async {
        if let reason = unavailableReason { fail(index, reason); return }
        let current = (session as? LanguageModelSession) ?? Self.makeSession()
        session = current
        do {
            // A little less random than the default: answers stick to what the tools said.
            for try await snapshot in current.streamResponse(to: question, options: GenerationOptions(temperature: 0.5)) {
                guard messages.indices.contains(index) else { return }
                messages[index].text = snapshot.content
            }
            if messages.indices.contains(index), messages[index].text.isEmpty {
                fail(index, "Botan had nothing to say. Try asking another way.")
            }
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                // The iPhone's model has a small memory: start again, keeping the screen.
                session = nil
                fail(index, "This chat got too long for the iPhone's model. Botan starts fresh: ask again.")
            case .guardrailViolation:
                fail(index, "Apple's model won't answer that one.")
            case .unsupportedLanguageOrLocale:
                fail(index, "Apple's model doesn't speak this language yet.")
            default:
                fail(index, "Botan couldn't answer. Try again.")
            }
        } catch {
            fail(index, "Botan couldn't answer. Try again.")
        }
    }

    @available(iOS 26.0, *)
    private static func makeSession() -> LanguageModelSession {
        let today = Date().formatted(date: .complete, time: .shortened)
        // The iPhone's language, named in English for the model ("French").
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let language = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
        return LanguageModelSession(
            tools: [AgentsNowTool(), HistoryTool(), ServicesTool(), LastTurnTool()],
            instructions: """
            You are Botan: a small, warm and witty character (Mochi) who lives in the user's \
            iPhone and keeps an eye on their Mac for them. You talk like a friend who is a good \
            developer: casual, direct, a little playful, never robotic.

            What you can look at, with your tools: the coding agents running on the Mac (Claude \
            Code, Cursor, Codex…), the services (Stripe payments, Vercel deploys, GitHub, n8n, \
            crypto, mail…) and the history of what happened and what the user allowed.

            How to answer:
            - Hello, thanks, small talk or a question about you: just answer, in one friendly \
            sentence, without any tool and without listing data nobody asked for.
            - A question about agents, projects, money, deploys, errors, mail or what happened: \
            call the right tool first, then answer from what it returned.
            - Never invent a number, a name or an event. If a tool returns nothing, say so.
            - Reply in the language of the user's message. If it's too short to tell, reply in \
            \(language).
            - Keep it short: one to three sentences, or a few bullet points for lists. Give the \
            key fact first.
            - You can't approve, deny or run anything. To start a task on the Mac, the user taps \
            the pencil on the Agents tab.

            Now: \(today).
            """
        )
    }
    #endif
}

// MARK: - What the model can read

#if canImport(FoundationModels)
/// Lines the tools return, kept short: the on-device model has a small context.
private enum ToolText {
    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? "today \(date.formatted(date: .omitted, time: .shortened))"
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func matches(_ text: String, _ filter: String) -> Bool {
        let words = filter.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count > 1 }
        guard !words.isEmpty else { return true }
        let haystack = text.lowercased()
        return words.contains { haystack.contains($0) }
    }

    static func clip(_ text: String, _ count: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > count ? String(flat.prefix(count)) + "…" : flat
    }

    static func service(_ pillId: String) -> String {
        PillCatalog.definition(for: pillId)?.name ?? pillId
    }
}

@available(iOS 26.0, *)
struct AgentsNowTool: Tool {
    let name = "agentsNow"
    let description = "The coding agents on the Mac right now: what each is doing, its project, its current step, and what waits for the user's OK."

    @Generable
    struct Arguments {
        @Guide(description: "An agent or project name to focus on, or empty for all")
        var filter: String
    }

    func call(arguments: Arguments) async throws -> String {
        let filter = arguments.filter
        return await MainActor.run {
            let link = PhoneLink.shared
            let sessions = link.sessions.filter {
                ToolText.matches("\($0.pillName) \($0.name) \(URL(fileURLWithPath: $0.cwd).lastPathComponent)", filter)
            }
            guard !sessions.isEmpty else { return "No agent session on the Mac right now." }
            return sessions.prefix(8).map { session in
                var line = "\(session.pillName) in \(session.name): \(session.statusText)"
                if let step = session.currentStep, !step.isEmpty { line += ", step: \(ToolText.clip(step, 80))" }
                if session.needsApproval, !session.approvalCommand.isEmpty {
                    line += ", waiting to run: \(ToolText.clip(session.approvalCommand, 120))"
                }
                if !session.question.isEmpty { line += ", asks: \(ToolText.clip(session.question, 120))" }
                return line + " (\(ToolText.when(session.updatedAt)))"
            }.joined(separator: "\n")
        }
    }
}

@available(iOS 26.0, *)
struct HistoryTool: Tool {
    let name = "history"
    let description = "What happened, newest first: payments, deploys, GitHub events, errors, agent turns, tasks started from the iPhone, and the actions the user allowed or denied. Kept 90 days."

    @Generable
    struct Arguments {
        @Guide(description: "Words to look for (a project, a service, a customer, 'deploy', 'error'…), or empty for everything")
        var query: String
        @Guide(description: "How many days back: 1 for today, 7 for a week, up to 90")
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let query = arguments.query
        let days = arguments.days
        return await MainActor.run {
            let since = Calendar.current.startOfDay(for: Date())
                .addingTimeInterval(-Double(max(0, min(days, 90) - 1)) * 86_400)
            let found = Journal.shared.entries.filter { entry in
                entry.date >= since
                    && ToolText.matches("\(ToolText.service(entry.pillId)) \(entry.title) \(entry.detail) \(entry.themes.map(\.title).joined(separator: " "))",
                                        query)
            }
            guard !found.isEmpty else { return "Nothing in the history for that." }
            var lines = found.prefix(15).map {
                "\(ToolText.when($0.date)) · \(ToolText.service($0.pillId)) · \(ToolText.clip($0.title, 70))"
                    + ($0.detail.isEmpty ? "" : " — \(ToolText.clip($0.detail, 90))")
            }
            if found.count > 15 { lines.append("…and \(found.count - 15) more.") }
            return lines.joined(separator: "\n")
        }
    }
}

@available(iOS 26.0, *)
struct ServicesTool: Tool {
    let name = "services"
    let description = "The services the Mac watches (Stripe, Vercel, GitHub, n8n, Resend, Cal.com, Notion, crypto, mail…): their state, today's figures and latest events."

    @Generable
    struct Arguments {
        @Guide(description: "A service name, or empty for an overview of all of them")
        var service: String
    }

    func call(arguments: Arguments) async throws -> String {
        let service = arguments.service
        return await MainActor.run {
            let snapshots = PhoneLink.shared.services.values.sorted { ToolText.service($0.pillId) < ToolText.service($1.pillId) }
            guard !snapshots.isEmpty else { return "The Mac shares no service yet." }
            let wanted = snapshots.filter { ToolText.matches(ToolText.service($0.pillId), service) }
            // One service: its figures and events. Otherwise one line each.
            if wanted.count == 1, let one = wanted.first {
                var lines = ["\(ToolText.service(one.pillId)): \(one.headline)" + (one.reason.isEmpty ? "" : " (\(one.reason))")]
                if let today = one.today, !today.isEmpty {
                    lines.append("Today: " + today.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
                }
                for section in one.sections {
                    for item in section.items.prefix(6) {
                        var line = "\(section.title): \(ToolText.clip(item.title, 70))"
                        if !item.detail.isEmpty { line += " — \(ToolText.clip(item.detail, 80))" }
                        if let date = item.date { line += " (\(ToolText.when(date)))" }
                        lines.append(line)
                    }
                }
                return lines.prefix(25).joined(separator: "\n")
            }
            let list = wanted.isEmpty ? snapshots : wanted
            return list.map { snapshot in
                var line = "\(ToolText.service(snapshot.pillId)): \(snapshot.headline)"
                if let today = snapshot.today, !today.isEmpty {
                    line += " — today " + today.prefix(3).map { "\($0.label) \($0.value)" }.joined(separator: ", ")
                }
                return line
            }.joined(separator: "\n")
        }
    }
}

@available(iOS 26.0, *)
struct LastTurnTool: Tool {
    let name = "lastTurn"
    let description = "The last thing an agent did: what it was asked, the files it changed and its final answer."

    @Generable
    struct Arguments {
        @Guide(description: "An agent or project name, or empty for the most recent one")
        var agent: String
    }

    func call(arguments: Arguments) async throws -> String {
        let agent = arguments.agent
        return await MainActor.run {
            let turns = PhoneLink.shared.turns.values
                .filter { ToolText.matches("\(ToolText.service($0.pillId)) \($0.project)", agent) }
                .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            guard let turn = turns.first else { return "No recent turn for that agent." }
            var lines = ["\(ToolText.service(turn.pillId)) in \(turn.project), \(ToolText.when(turn.startedAt))"
                         + (turn.endedAt == nil ? ", still working" : "")]
            lines.append("Asked: \(ToolText.clip(turn.prompt, 300))")
            if !turn.files.isEmpty {
                lines.append("Files: " + turn.files.prefix(8).map {
                    "\(URL(fileURLWithPath: $0.path).lastPathComponent) (+\($0.added) −\($0.removed))"
                }.joined(separator: ", "))
            }
            if !turn.finalMessage.isEmpty { lines.append("Answer: \(ToolText.clip(turn.finalMessage, 500))") }
            return lines.joined(separator: "\n")
        }
    }
}
#endif

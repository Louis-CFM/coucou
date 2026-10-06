import AppIntents
import Foundation

// Siri and the Shortcuts app: ask where your agents are, or send Claude the
// next instruction. Sending needs the iPhone unlocked by its owner, like the
// instruction field in the app needs Face ID.

struct AgentsStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Agent status"
    static var description: IntentDescription { IntentDescription("What your agents are doing on your Mac.") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let link = PhoneLink.shared
        await link.refresh()
        let sessions = link.sessions.sortedByUrgency()
        guard let lead = sessions.first else {
            return .result(dialog: "All quiet: no agent session on your Mac.")
        }
        let summary = sessions.summary ?? "All quiet"
        return .result(dialog: "\(summary). \(lead.pillName), \(lead.title): \(lead.statusText).")
    }
}

struct AskClaudeIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Claude"
    static var description: IntentDescription {
        IntentDescription("Sends the next instruction to your Claude Code session on your Mac.")
    }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Instruction", requestValueDialog: "What should Claude do?")
    var instruction: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let link = PhoneLink.shared
        await link.refresh()
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result(dialog: "Nothing to send.") }
        // The Claude Code session that last moved and takes instructions.
        guard let session = link.sessions
            .filter({ $0.acceptsInstructions })
            .max(by: { $0.updatedAt < $1.updatedAt }) else {
            return .result(dialog: "No Claude Code session takes instructions. Turn it on in Coucou's Settings on your Mac.")
        }
        guard await link.sendInstruction(text, pillId: session.id) else {
            return .result(dialog: "Couldn't reach iCloud. Nothing was sent.")
        }
        return .result(dialog: "Sent to Claude in \(session.title). Your Mac picks it up within 15 seconds.")
    }
}

struct CoucouShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskClaudeIntent(),
                    phrases: ["Ask Claude in \(.applicationName)",
                              "Tell Claude with \(.applicationName)",
                              "Send an instruction with \(.applicationName)"],
                    shortTitle: "Ask Claude",
                    systemImageName: "text.bubble")
        AppShortcut(intent: AgentsStatusIntent(),
                    phrases: ["What are my agents doing in \(.applicationName)",
                              "\(.applicationName) status",
                              "Agent status in \(.applicationName)"],
                    shortTitle: "Agent status",
                    systemImageName: "sparkles")
    }
}

/// A Focus filter: in a Focus (Sleep, Work…), Coucou can keep quiet about
/// finished and failed agents and only notify what waits on you.
struct CoucouFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Coucou"
    static var description: IntentDescription {
        IntentDescription("Choose what Coucou notifies during this Focus.")
    }

    @Parameter(title: "Only approvals and questions", default: false)
    var onlyWaiting: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: onlyWaiting ? "Only approvals and questions" : "Everything")
    }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(onlyWaiting, forKey: PhoneSettings.focusOnlyWaitingKey)
        return .result()
    }
}

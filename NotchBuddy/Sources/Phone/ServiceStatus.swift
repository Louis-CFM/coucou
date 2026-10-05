import SwiftUI

// How a service Mochi reads on the iPhone: its dot color, a short status, and
// what the widgets get.

extension ServiceTone {
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .info: Color(red: 0.4, green: 0.7, blue: 1)
        case .idle: .secondary
        }
    }

    var label: String {
        switch self {
        case .ok: "all good"
        case .warning: "needs a look"
        case .error: "something failed"
        case .info: "news"
        case .idle: "quiet"
        }
    }

    /// The Mochi face for this tone.
    var botState: BotState {
        switch self {
        case .ok: .finished
        case .error: .error
        case .warning: .question
        case .info, .idle: .idle
        }
    }
}

extension ServiceSnapshot {
    var name: String { PillCatalog.definition(for: pillId)?.name ?? pillId }
    var color: String { PillCatalog.definition(for: pillId)?.color ?? "#C0C4CC" }

    /// What the widgets get (SharedSessions).
    var shared: SharedSession {
        let tone: SharedSession.Tone
        let urgency: Int
        switch self.tone {
        case .error: tone = .error; urgency = 2
        case .warning: tone = .warning; urgency = 3
        case .ok: tone = .done; urgency = 4
        case .info: tone = .info; urgency = 4
        case .idle: tone = .idle; urgency = 6
        }
        return SharedSession(id: pillId, title: name, agent: name, color: color,
                             state: (self.tone == .ok ? BotState.idle : self.tone.botState).rawValue,
                             statusText: self.tone.label, tone: tone, urgency: urgency,
                             stepIndex: 0, stepCount: 0, currentStep: headline, updatedAt: updatedAt)
    }
}

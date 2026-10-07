import AppIntents
import SwiftUI
import WidgetKit

// A Control Center button: the agent that needs you most and what it does;
// a tap opens it in Coucou. The app reloads it with the widgets.

struct CoucouControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "fr.louisraille.Coucou.lead", provider: LeadProvider()) { lead in
            ControlWidgetButton(action: OpenLeadMochiIntent()) {
                Label(lead.text, systemImage: lead.symbol)
            }
        }
        .displayName("Coucou")
        .description("Your agents at a glance. Opens the one that needs you.")
    }
}

struct LeadStatus: Sendable {
    let text: String
    let symbol: String

    static let quiet = LeadStatus(text: "All quiet", symbol: "moon.zzz.fill")

    init(text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    init(_ session: SharedSession?) {
        guard let session, session.tone != .idle else { self = .quiet; return }
        text = "\(session.agent): \(session.statusText)"
        switch session.tone {
        case .waiting: symbol = "hand.raised.fill"
        case .question: symbol = "questionmark.bubble.fill"
        case .error: symbol = "exclamationmark.triangle.fill"
        case .working: symbol = "hammer.fill"
        case .done: symbol = "checkmark.circle.fill"
        case .warning: symbol = "exclamationmark.circle.fill"
        case .info: symbol = "bell.fill"
        case .idle: symbol = "moon.zzz.fill"
        }
    }
}

struct LeadProvider: ControlValueProvider {
    var previewValue: LeadStatus { LeadStatus(text: "VS Code: waiting for your OK", symbol: "hand.raised.fill") }

    func currentValue() async throws -> LeadStatus {
        LeadStatus(SharedSessions.load().first)
    }
}

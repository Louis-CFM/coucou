import AppIntents
import Foundation

/// Opens Coucou on the Mochi that needs you most (Control Center button).
/// Compiled into the app and the widgets extension.
struct OpenLeadMochiIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the agent that needs you"

    func perform() async throws -> some IntentResult & OpensIntent {
        let url = SharedSessions.load().first.map { SharedSession.url(for: $0.id) } ?? URL(string: "coucou://home")!
        return .result(opensIntent: OpenURLIntent(url))
    }
}

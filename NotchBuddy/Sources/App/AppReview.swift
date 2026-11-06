import SwiftUI
#if APPSTORE
import StoreKit
#endif

/// The App Store build asks for a review after a good moment: a Claude Code session that
/// finished, the 8th one at least, never in the first three days, once per version
/// (ReviewPolicy). The request is Apple's own: macOS decides whether it shows, at most three
/// times a year, and never to someone who turned it off. The GitHub build never asks.
@MainActor
enum AppReview {
    static func noteFinished() {
        #if APPSTORE
        guard ReviewPolicy.note(needed: ReviewPolicy.macMoments) else { return }
        // Once the finished card has had its moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            appendAppLog("nb.log", "[Review] asking for an App Store review")
            NotificationCenter.default.post(name: .askAppReview, object: nil)
        }
        #endif
    }
}

extension Notification.Name {
    static let askAppReview = Notification.Name("notchBuddy.askAppReview")
}

/// On the island's root view: the request needs a SwiftUI view on screen to come from.
struct AppReviewAsker: ViewModifier {
    #if APPSTORE
    @Environment(\.requestReview) private var requestReview
    #endif

    func body(content: Content) -> some View {
        #if APPSTORE
        content.onReceive(NotificationCenter.default.publisher(for: .askAppReview)) { _ in requestReview() }
        #else
        content
        #endif
    }
}

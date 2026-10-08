import UIKit

/// Small taps under the finger for the actions that reach the Mac.
@MainActor
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func impact() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

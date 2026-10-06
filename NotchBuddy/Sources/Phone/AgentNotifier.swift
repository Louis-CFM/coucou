import Foundation
import UIKit
import UserNotifications

/// The iPhone's notification settings (Settings → Notifications), kept on the iPhone.
enum PhoneSettings {
    static let notifyDoneKey = "notifyDone"
    static let mochiSoundsKey = "mochiSounds"
    static let quietHoursKey = "quietHours"
    static let quietFromKey = "quietFrom"   // minutes after midnight
    static let quietToKey = "quietTo"

    private static var defaults: UserDefaults { .standard }

    /// A notification when an agent finishes or fails (on by default).
    static var notifyDone: Bool { defaults.object(forKey: notifyDoneKey) as? Bool ?? true }
    /// Mochi's own sounds instead of the iPhone's default one (on by default).
    static var mochiSounds: Bool { defaults.object(forKey: mochiSoundsKey) as? Bool ?? true }
    static var quietHours: Bool { defaults.bool(forKey: quietHoursKey) }
    static var quietFrom: Int { defaults.object(forKey: quietFromKey) as? Int ?? 22 * 60 }
    static var quietTo: Int { defaults.object(forKey: quietToKey) as? Int ?? 8 * 60 }

    /// Inside the quiet hours: only what waits on you (approvals, questions) makes a sound.
    static func isQuiet(at date: Date = .now) -> Bool {
        guard quietHours else { return false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let from = quietFrom, to = quietTo
        if from == to { return false }
        return from < to ? (now >= from && now < to) : (now >= from || now < to)
    }

    /// One of Mochi's sounds (bundled WAV), or the iPhone's default.
    static func sound(_ name: String) -> UNNotificationSound {
        mochiSounds ? UNNotificationSound(named: UNNotificationSoundName("\(name).wav")) : .default
    }
}

/// Notification categories and their actions.
enum NotificationActions {
    // Approvals: Allow and Deny answer right there (iOS asks to unlock first).
    static let approvalCategory = "COUCOU_APPROVAL"
    static let allow = "COUCOU_ALLOW"
    static let review = "COUCOU_REVIEW"
    static let deny = "COUCOU_DENY"
    // An agent finished: reply with the next instruction.
    static let doneReplyCategory = "COUCOU_DONE_REPLY"
    static let doneCategory = "COUCOU_DONE"
    static let reply = "COUCOU_REPLY"
    // A question: one button per choice when it is a single question.
    static let questionCategory = "COUCOU_QUESTION"
    static let pickPrefix = "COUCOU_PICK_"

    /// Categories made for the latest questions, kept next to the fixed ones.
    @MainActor private static var questionCategories: [UNNotificationCategory] = []

    @MainActor static func register() {
        let allow = UNNotificationAction(identifier: allow, title: "Allow",
                                         options: [.authenticationRequired],
                                         icon: UNNotificationActionIcon(systemImageName: "faceid"))
        let review = UNNotificationAction(identifier: review, title: "Review",
                                          options: [.foreground, .authenticationRequired])
        let deny = UNNotificationAction(identifier: deny, title: "Deny",
                                        options: [.destructive, .authenticationRequired])
        let approval = UNNotificationCategory(identifier: approvalCategory, actions: [allow, review, deny],
                                              intentIdentifiers: [], options: [])
        let reply = UNTextInputNotificationAction(identifier: reply, title: "Reply",
                                                  options: [.authenticationRequired],
                                                  icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: "Send",
                                                  textInputPlaceholder: "Tell Claude what to do next…")
        let doneReply = UNNotificationCategory(identifier: doneReplyCategory, actions: [reply],
                                               intentIdentifiers: [], options: [])
        let done = UNNotificationCategory(identifier: doneCategory, actions: [], intentIdentifiers: [], options: [])
        let question = UNNotificationCategory(identifier: questionCategory, actions: [],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories(
            Set([approval, doneReply, done, question] + questionCategories))
    }

    /// A category with one button per choice of this question; nil when it
    /// has several questions or allows several picks (answered in the app).
    @MainActor static func category(for payload: QuestionPayload) -> String? {
        guard payload.items.count == 1, let item = payload.items.first, !item.multiSelect else { return nil }
        let id = "COUCOU_Q_\(payload.fingerprint.prefix(16))"
        let actions = item.options.prefix(4).enumerated().map { index, option in
            UNNotificationAction(identifier: "\(pickPrefix)\(index)", title: option.label,
                                 options: [.authenticationRequired])
        }
        questionCategories.removeAll { $0.identifier == id }
        questionCategories.append(UNNotificationCategory(identifier: id, actions: Array(actions),
                                                         intentIdentifiers: [], options: []))
        questionCategories = Array(questionCategories.suffix(3))
        register()
        return id
    }
}

/// Local notifications for what happens on the Mac while the app is in the
/// background: an agent finished or failed, or asks a question. Approvals
/// have their own path (PhoneLink). Each event is notified once, and only if
/// it happened in the last 10 minutes.
@MainActor
enum AgentNotifier {
    enum Event {
        case finished(SessionItem)
        case failed(SessionItem)
        case question(SessionItem, QuestionPayload)
    }

    private static let seenKey = "notifiedEvents"

    /// What each session looked like the last time, kept across launches so
    /// an app woken by a push still sees what changed.
    private static var lastSeen: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    /// The event this new session record brings, if any.
    static func event(for session: SessionItem) -> Event? {
        let key: String
        switch session.state {
        case .finished: key = "finished"
        case .error: key = "error"
        default: key = session.questionFingerprint.isEmpty ? session.state.rawValue : "q-\(session.questionFingerprint)"
        }
        let before = lastSeen[session.id]
        lastSeen[session.id] = key
        guard before != key, Date().timeIntervalSince(session.updatedAt) < 600 else { return nil }
        if let payload = session.questionPayload, !session.questionFingerprint.isEmpty, key.hasPrefix("q-") {
            return .question(session, payload)
        }
        if key == "finished" { return .finished(session) }
        if key == "error" { return .failed(session) }
        return nil
    }

    static func post(_ event: Event, turn: TurnSnapshot?) async {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        let quiet = PhoneSettings.isQuiet()
        switch event {
        case .finished(let session):
            guard PhoneSettings.notifyDone else { return }
            content.title = "\(session.pillName) · \(session.title)"
            let answer = turn.map(\.finalMessage).flatMap { $0.isEmpty ? nil : $0 } ?? session.finalLine
            content.body = answer.isEmpty ? "Done. What's next?" : "✓ " + String(answer.prefix(220))
            content.sound = quiet ? nil : PhoneSettings.sound("finish")
            content.categoryIdentifier = session.acceptsInstructions
                ? NotificationActions.doneReplyCategory : NotificationActions.doneCategory
            content.userInfo = ["pillId": session.id, "kind": "done"]
            if quiet { content.interruptionLevel = .passive }
        case .failed(let session):
            guard PhoneSettings.notifyDone else { return }
            content.title = "\(session.pillName) · \(session.title)"
            content.body = session.finalLine.isEmpty ? "Something went wrong." : String(session.finalLine.prefix(220))
            content.sound = quiet ? nil : PhoneSettings.sound("error")
            content.categoryIdentifier = session.acceptsInstructions
                ? NotificationActions.doneReplyCategory : NotificationActions.doneCategory
            content.userInfo = ["pillId": session.id, "kind": "done"]
            if quiet { content.interruptionLevel = .passive }
        case .question(let session, let payload):
            // A question blocks the agent like an approval: it rings in the quiet hours too.
            content.title = "\(session.pillName) has a question"
            let first = payload.items.first
            content.body = first.map { item in
                item.question + "\n" + item.options.map { "• \($0.label)" }.joined(separator: "\n")
            } ?? session.question
            content.sound = PhoneSettings.sound("question")
            content.categoryIdentifier = NotificationActions.category(for: payload) ?? NotificationActions.questionCategory
            content.userInfo = ["pillId": session.id, "kind": "question",
                                "fingerprint": session.questionFingerprint,
                                "options": first?.options.prefix(4).map(\.label) ?? []]
            // Let iOS take the new category before the notification shows.
            try? await Task.sleep(for: .milliseconds(300))
        }
        content.threadIdentifier = content.userInfo["pillId"] as? String ?? "coucou"
        let kind = content.userInfo["kind"] as? String ?? "event"
        let request = UNNotificationRequest(identifier: "\(kind)-\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

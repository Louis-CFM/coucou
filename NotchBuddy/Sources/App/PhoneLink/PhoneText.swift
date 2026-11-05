#if PHONE_LINK
import Foundation

/// Texts the Mac shows localized but sends to the iPhone in English (the iPhone app has no catalog).
/// Only the fixed texts and the few templates the Mac builds itself are recognized; anything else (names,
/// subjects, messages written by a service) goes through unchanged.
enum PhoneText {
    private static let fixed: [String: String] = [
        String(localized: "Session"): "Session",
        String(localized: "⚠ failed"): "⚠ failed",
        String(localized: "+ subagent"): "+ subagent",
        String(localized: "• subagent done"): "• subagent done",
        String(localized: "Invalid API key (401)"): "Invalid API key (401)",
        String(localized: "Use secret key (sk_live_… not pk_live_…)"): "Use secret key (sk_live_… not pk_live_…)",
        String(localized: "No connection"): "No connection",
        String(localized: "Untitled"): "Untitled",
        String(localized: "Meeting"): "Meeting",
    ]

    /// Templates with dynamic parts: a localized sample built with markers, and the English text with the same markers.
    private static let m0 = "\u{1}0\u{1}", m1 = "\u{1}1\u{1}"
    private static let templates: [(sample: String, english: String)] = [
        (String(localized: "API error \(m0)"), "API error \(m0)"),
        (String(localized: "→ \(m0) · 1 item"), "→ \(m0) · 1 item"),
        (String(localized: "→ \(m0) · \(m1) items"), "→ \(m0) · \(m1) items"),
    ]

    static func english(_ text: String) -> String {
        if let known = fixed[text] { return known }
        for t in templates {
            if let out = fill(text, sample: t.sample, english: t.english) { return out }
        }
        return text
    }

    /// Splits `sample` on the markers, matches `text` against the fixed pieces, and puts what the markers
    /// stood for into `english`. Nil when `text` is not an instance of the sample.
    private static func fill(_ text: String, sample: String, english: String) -> String? {
        var pieces: [String] = []
        var order: [String] = []
        var rest = Substring(sample)
        while let r = [m0, m1].compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            pieces.append(String(rest[..<r.lowerBound]))
            order.append(String(rest[r]))
            rest = rest[r.upperBound...]
        }
        pieces.append(String(rest))
        if order.isEmpty { return nil }
        guard text.hasPrefix(pieces[0]), text.hasSuffix(pieces[pieces.count - 1]),
              text.count >= pieces[0].count + pieces[pieces.count - 1].count else { return nil }
        var cursor = text.index(text.startIndex, offsetBy: pieces[0].count)
        let end = text.index(text.endIndex, offsetBy: -pieces[pieces.count - 1].count)
        var values: [String: String] = [:]
        for (i, marker) in order.enumerated() {
            if i == order.count - 1 {
                values[marker] = String(text[cursor..<end])
            } else {
                guard let r = text.range(of: pieces[i + 1], range: cursor..<end) else { return nil }
                values[marker] = String(text[cursor..<r.lowerBound])
                cursor = r.upperBound
            }
        }
        var out = english
        for (marker, value) in values { out = out.replacingOccurrences(of: marker, with: value) }
        return out
    }
}
#endif

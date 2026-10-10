import Foundation

/// The Meet, Zoom or Teams link of a calendar event. Pure, so it can be tested on its own.
enum CalendarJoinLink {
    private static let pattern = try! NSRegularExpression(
        pattern: #"https://(?:meet\.google\.com/[a-z0-9-]+|(?:[\w-]+\.)?zoom\.us/(?:j|my|w|s)/[^\s"<>\\]+|teams\.microsoft\.com/l/meetup-join/[^\s"<>\\]+|teams\.live\.com/meet/[^\s"<>\\]+)"#,
        options: [.caseInsensitive])

    /// A link longer than this is not a meeting link.
    private static let maxLength = 2048
    /// ) . , ; — punctuation that ends a sentence, not a link.
    private static let trailing: Set<UInt8> = [0x29, 0x2E, 0x2C, 0x3B]

    /// The first link in these texts, in order.
    static func find(_ texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.firstMatch(in: text, range: range),
                  let r = Range(match.range, in: text) else { continue }
            // A loop, not [).,;]+$: that regex is quadratic on a long run of dots.
            let bytes = Array(text[r].utf8)
            var end = bytes.count
            while end > 0, trailing.contains(bytes[end - 1]) { end -= 1 }
            guard end <= maxLength else { continue }
            let link = String(decoding: bytes[..<end], as: UTF8.self)
            if isWhole(link), let url = URL(string: link) { return url }
        }
        return nil
    }

    /// Still a meeting link once its trailing marks are gone.
    private static func isWhole(_ link: String) -> Bool {
        let range = NSRange(link.startIndex..., in: link)
        return pattern.firstMatch(in: link, range: range)?.range == range
    }
}

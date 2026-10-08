import Foundation

/// Extracts the assistant's full text from an Anthropic Messages API content array.
/// Web-search responses interleave text with tool blocks, and citations can
/// split a sentence across adjacent text blocks. Keep the original text and
/// whitespace without inserting separators, then trim only the complete result.
/// Returns nil when the response carries no assistant text at all.
func claudeResponseText(fromContent content: [[String: Any]]) -> String? {
    let text = content.compactMap { block -> String? in
        guard block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
    }
    .joined()
    .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

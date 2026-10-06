import Foundation

enum MemoryExportFormat: String, Codable { case json, markdown }

struct MemoryExport: Codable, Equatable {
    var content: String
    var filename: String
}

enum MemoryExportFormatter {
    private struct SafeMemory: Encodable {
        var id: String
        var text: String
        var factType: MemoryFactType
        var state: MemoryState
        var context: String?
        var tags: [String]
        var entities: [String]
        var createdAt: String?
        var updatedAt: String?
        var mentionedAt: String?
        var occurredStart: String?
        var occurredEnd: String?
        var editedAt: String?
        var provenance: [String: String]
    }

    static func formatPage(_ page: MemoryPage, as format: MemoryExportFormat) throws -> MemoryExport {
        try format(page.items, as: format)
    }

    static func format(_ records: [MemoryRecord], as format: MemoryExportFormat, credential: String = "") throws -> MemoryExport {
        let records = records.map { redact($0, credential: credential) }
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(records.map(safeMemory))
            return MemoryExport(content: String(decoding: data, as: UTF8.self) + "\n", filename: "coucou-memories.json")
        case .markdown:
            var output = "# Coucou Memories\n\n"
            for record in records {
                output += "## \(markdownInline(record.id))\n\n"
                let fence = markdownFence(record.text)
                output += "\(fence)\n\(record.text)\n\(fence)\n\n"
                output += "- State: `\(record.state.rawValue)`\n- Type: `\(record.factType.rawValue)`\n"
                for (label, value) in [
                    ("Created", record.createdAt), ("Updated", record.updatedAt), ("Mentioned", record.mentionedAt),
                    ("Occurred start", record.occurredStart), ("Occurred end", record.occurredEnd), ("Edited", record.editedAt),
                ] where value != nil {
                    output += "- \(label): \(markdownCodeSpan(value!))\n"
                }
                if !record.tags.isEmpty { output += "- Tags: \(record.tags.map(markdownInline).joined(separator: ", "))\n" }
                let provenance = safeProvenance(record.metadata)
                if !provenance.isEmpty {
                    output += "- Provenance:\n"
                    for key in provenance.keys.sorted() {
                        let value = provenance[key]!
                        let rendered = key == "coucou.timestamp" || key == "coucou.remoteTimestamp" ? markdownCodeSpan(value) : markdownInline(value)
                        output += "  - `\(markdownCode(key))`: \(rendered)\n"
                    }
                }
                output += "\n"
            }
            return MemoryExport(content: output, filename: "coucou-memories.md")
        }
    }

    private static func redact(_ value: MemoryRecord, credential: String) -> MemoryRecord {
        var record = value
        record.id = redact(record.id, credential: credential)
        record.text = redact(record.text, credential: credential)
        record.context = record.context.map { redact($0, credential: credential) }
        record.tags = record.tags.map { redact($0, credential: credential) }
        record.entities = record.entities.map { redact($0, credential: credential) }
        record.createdAt = record.createdAt.map { redact($0, credential: credential) }
        record.updatedAt = record.updatedAt.map { redact($0, credential: credential) }
        record.mentionedAt = record.mentionedAt.map { redact($0, credential: credential) }
        record.occurredStart = record.occurredStart.map { redact($0, credential: credential) }
        record.occurredEnd = record.occurredEnd.map { redact($0, credential: credential) }
        record.editedAt = record.editedAt.map { redact($0, credential: credential) }
        record.metadata = record.metadata.mapValues { value in
            if case .string(let text) = value { return .string(redact(text, credential: credential)) }
            return value
        }
        return record
    }

    private static func redact(_ value: String, credential: String) -> String {
        var output = credential.isEmpty ? value : value.replacingOccurrences(of: credential, with: "[REDACTED]")
        guard !hindsightTextContainsSecret(output) else { return "[REDACTED]" }
        for word in output.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.+/=").inverted)
            if hindsightTextContainsSecret(token) { output = output.replacingOccurrences(of: token, with: "[REDACTED]") }
        }
        return output
    }

    private static func safeMemory(_ record: MemoryRecord) -> SafeMemory {
        SafeMemory(
            id: record.id, text: record.text, factType: record.factType, state: record.state,
            context: record.context, tags: record.tags, entities: record.entities,
            createdAt: record.createdAt, updatedAt: record.updatedAt, mentionedAt: record.mentionedAt,
            occurredStart: record.occurredStart, occurredEnd: record.occurredEnd, editedAt: record.editedAt,
            provenance: safeProvenance(record.metadata)
        )
    }

    private static let safeProvenanceKeys: Set<String> = [
        "coucou.turnId", "coucou.timestamp", "coucou.platform", "coucou.provider", "coucou.model",
        "coucou.contextKind", "coucou.contextLabel", "coucou.retentionKind", "coucou.sourceRole",
        "coucou.sourceSpan", "coucou.tenant", "coucou.bank", "coucou.remoteIds", "coucou.remoteTimestamp",
    ]

    private static func safeProvenance(_ metadata: [String: JSONValue]) -> [String: String] {
        metadata.reduce(into: [:]) { result, pair in
            if safeProvenanceKeys.contains(pair.key), case .string(let value) = pair.value { result[pair.key] = value }
        }
    }

    private static func markdownFence(_ value: String) -> String {
        let longest = value.split(whereSeparator: { $0 != "`" }, omittingEmptySubsequences: false).map(\.count).max() ?? 0
        return String(repeating: "`", count: max(3, longest + 1))
    }

    private static func markdownInline(_ value: String) -> String {
        let special = CharacterSet(charactersIn: "\\`*_{}[]<>()#+-.!|")
        return value.unicodeScalars.map { scalar in
            if scalar == "\n" || scalar == "\r" { return " " }
            return special.contains(scalar) ? "\\\(Character(scalar))" : String(Character(scalar))
        }.joined()
    }

    private static func markdownCode(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func markdownCodeSpan(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let longest = normalized.split(whereSeparator: { $0 != "`" }, omittingEmptySubsequences: false).map(\.count).max() ?? 0
        let delimiter = String(repeating: "`", count: longest + 1)
        let needsPadding = normalized.first == "`" || normalized.first == " " || normalized.last == "`" || normalized.last == " "
        return needsPadding ? "\(delimiter) \(normalized) \(delimiter)" : "\(delimiter)\(normalized)\(delimiter)"
    }
}

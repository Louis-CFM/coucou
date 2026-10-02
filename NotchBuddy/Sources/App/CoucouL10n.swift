import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case en, es

    var id: String { rawValue }
}

extension Notification.Name {
    static let coucouLanguageChanged = Notification.Name("coucouLanguageChanged")
}

/// English sentence is the key. Spanish lives in Resources/CoucouStrings/es.strings.
enum CoucouL10n {
    nonisolated(unsafe) private(set) static var language: AppLanguage = .en
    nonisolated(unsafe) private static var tables: [String: [String: String]] = [:]

    static func apply(_ language: AppLanguage) {
        self.language = language
        loadIfNeeded()
        NotificationCenter.default.post(name: .coucouLanguageChanged, object: language)
    }

    static func string(_ key: String) -> String {
        loadIfNeeded()
        return tables[language.rawValue]?[key] ?? key
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), locale: Locale(identifier: language.rawValue), arguments: args)
    }

    private static func loadIfNeeded() {
        guard tables.isEmpty else { return }
        for code in AppLanguage.allCases.map(\.rawValue) {
            tables[code] = loadTable(code)
        }
    }

    private static func loadTable(_ code: String) -> [String: String] {
        guard let url = Bundle.main.url(
            forResource: code, withExtension: "strings", subdirectory: "CoucouStrings"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    /// `"key" = "value";` lines. The files are ours, so the shape stays simple.
    private static func parse(_ text: String) -> [String: String] {
        var table: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard raw.hasPrefix("\""), let eq = raw.range(of: "\" = \"") else { continue }
            let key = String(raw[raw.index(after: raw.startIndex)..<eq.lowerBound])
            let valueStart = eq.upperBound
            guard let end = raw.range(of: "\";", range: valueStart..<raw.endIndex) else { continue }
            let value = String(raw[valueStart..<end.lowerBound])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
            table[key.replacingOccurrences(of: "\\\"", with: "\"")] = value
        }
        return table
    }
}

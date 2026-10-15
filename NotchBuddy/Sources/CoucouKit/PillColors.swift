import Foundation

/// A colour of the user's own for each pill's Mochi.
///
/// `PillCatalog` keeps every default. This holds only what the user changed, by
/// pill ID, so an empty preference paints the island exactly as the catalog
/// says. Same key and values on Windows and Linux (`pillColors` in
/// settings.json, read by windows/src/core/pill-colors.ts).
enum PillColors {

    /// What the palette offers, in the order it is shown. Every colour is one
    /// the catalog already uses, and all of them stay readable on the island's
    /// black with Mochi's dark eyes, which a free colour picker could not promise.
    static let palette: [String] = [
        "#F5F6F8", "#F4505E", "#F29B38", "#FACC15", "#4ADE80",
        "#2DD4BF", "#38BDF8", "#818CF8", "#C084FC", "#E879F9",
    ]

    /// "#RRGGBB" in upper case, or nil for anything that is not six hex digits.
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#" + digits.uppercased()
    }

    /// A stored preference → pill ID → colour. Whatever is not a colour is left
    /// out, so a damaged entry costs one pill its colour and nothing else. IDs
    /// are not checked against the catalog: a pill this build does not know
    /// keeps the colour a newer one gave it.
    static func parsed(_ raw: Any?) -> [String: String] {
        guard let entries = raw as? [String: Any] else { return [:] }
        var colors: [String: String] = [:]
        for (id, value) in entries {
            guard !id.isEmpty, let hex = normalized(value as? String) else { continue }
            colors[id] = hex
        }
        return colors
    }

    /// The colour a pill is painted with: the user's when there is one, else the catalog's.
    static func color(for id: String, catalogColor: String, in colors: [String: String]) -> String {
        normalized(colors[id]) ?? catalogColor
    }

    /// The preference once `hex` is picked for a pill. Picking nothing,
    /// something that is not a colour, or the pill's own catalog colour clears
    /// the entry: the preference never stores a default.
    static func picking(_ hex: String?, for id: String, catalogColor: String,
                        in colors: [String: String]) -> [String: String] {
        var next = parsed(colors)
        if let picked = normalized(hex), picked != normalized(catalogColor) {
            next[id] = picked
        } else {
            next.removeValue(forKey: id)
        }
        return next
    }

    // UserDefaults key "pillColors"; missing or unusable → no colour chosen.
    static var stored: [String: String] {
        get { parsed(UserDefaults.standard.dictionary(forKey: "pillColors")) }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: "pillColors")
            } else {
                UserDefaults.standard.set(newValue, forKey: "pillColors")
            }
        }
    }
}

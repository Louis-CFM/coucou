import Foundation

/// The menu bar's camera, microphone and screen dots, as Control Center logs them.
enum CallSensors {
    static let marker = "Active activity attributions changed to ["

    /// `cam`, `mic`, `scr` held by any app but `own`; nil for a line that is not an update.
    /// The screen counts only for an app also on the mic or camera, never a recorder.
    static func parse(_ line: String, own: String) -> Set<String>? {
        guard let start = line.range(of: marker),
              let end = line[start.upperBound...].firstIndex(of: "]") else { return nil }
        var apps: [String: Set<String>] = [:]
        for item in line[start.upperBound..<end].split(separator: ",") {
            let s = item.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            guard let colon = s.firstIndex(of: ":") else { continue }
            let app = String(s[s.index(after: colon)...])
            guard app != own else { continue }
            apps[app, default: []].insert(String(s[..<colon]))
        }
        var held: Set<String> = []
        for kinds in apps.values {
            let onCall = !kinds.isDisjoint(with: ["cam", "mic"])
            if kinds.contains("cam") { held.insert("cam") }
            if kinds.contains("mic") { held.insert("mic") }
            if kinds.contains("scr") && onCall { held.insert("scr") }
        }
        return held
    }
}

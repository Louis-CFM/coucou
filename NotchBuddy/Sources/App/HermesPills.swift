import Foundation

/// Colour and eye shape of a dynamic pill (cmux session, Hermes agent), derived from a stable key.
/// Shared by both builds: `CmuxRouting` (GitHub build only) delegates to it.
enum PillLook {
    static let palette = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9", "#F97316", "#2DD4BF", "#F472B6", "#A78BFA"]
    /// Raw values of EyeShape; `pill` means no override.
    static let eyes = ["pill", "wide", "dot", "happy", "cup"]

    /// FNV-1a 64 bit. Stable across launches, unlike hashValue.
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    /// The colour is probed linearly so two live pills never share one while fewer than 8 are live.
    static func appearance(key: String, takenColors: Set<String>) -> (color: String, eye: String) {
        let h = fnv1a(key)
        let base = Int(h % UInt64(palette.count))
        var color = palette[base]
        for i in 0..<palette.count {
            let c = palette[(base + i) % palette.count]
            if !takenColors.contains(c) { color = c; break }
        }
        return (color, eyes[Int((h >> 16) % UInt64(eyes.count))])
    }
}

/// Pure logic for the pill of each connected Hermes agent: task ids and their inverse, what to add
/// or remove, the card subtitle. The agent name (as typed) is the identity and the pill label.
enum HermesPills {
    /// Cannot collide with `agent_<name>` (external agents: lowercase, digits and dashes only, so no
    /// underscore after `agent`), `agent_cmux_`, `integration_*` or `ai_*`.
    static let taskPrefix = "agent_hermes_"
    static let maxKeyLength = 32

    static func isTaskId(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix(taskPrefix) && id.count > taskPrefix.count
    }

    /// The step numbers a pill sends to the iPhone (session list, Live Activity). The rows of a Hermes pill are for the
    /// overview card of the notch only, so their count and index never leave the Mac.
    static func publishedProgress(taskId: String, stepIndex: Int, stepCount: Int) -> (stepIndex: Int, stepCount: Int) {
        isTaskId(taskId) ? (0, 0) : (stepIndex, stepCount)
    }

    /// Lowercase a-z, 0-9 and dash only, capped. A name with none of them (e.g. only symbols) gets
    /// `x` plus a hash of the name, so every name has a usable key.
    static func sanitize(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let filtered = String(name.lowercased().filter { allowed.contains($0) }.prefix(maxKeyLength))
        if !filtered.isEmpty { return filtered }
        return "x" + hash(name)
    }

    private static func hash(_ name: String) -> String {
        String(String(PillLook.fnv1a(name), radix: 16).prefix(8))
    }

    /// Key of every name, in the order given. Names that sanitise to the same key are told apart by a
    /// hash of the raw name; the smallest raw name keeps the plain key, so the result does not depend
    /// on the order of the list.
    static func keys(for names: [String]) -> [String: String] {
        var groups: [String: [String]] = [:]
        for name in names { groups[sanitize(name), default: []].append(name) }
        var out: [String: String] = [:]
        for (key, group) in groups {
            let sorted = group.sorted { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
            for (i, name) in sorted.enumerated() {
                out[name] = i == 0 ? key : String(key.prefix(maxKeyLength - 9)) + "-" + hash(name)
            }
        }
        return out
    }

    /// Task id of every agent name.
    static func taskIds(for names: [String]) -> [String: String] {
        keys(for: names).mapValues { taskPrefix + $0 }
    }

    /// Inverse: the agent name behind a task id, among the connected names. nil when none matches.
    static func agentName(forTaskId id: String, in names: [String]) -> String? {
        guard isTaskId(id) else { return nil }
        let ids = taskIds(for: names)
        return names.first { ids[$0] == id }
    }

    /// Which pills to drop (ids with no agent) and which to create (agents with no pill), in list order.
    static func reconcile(existingIds: [String], agents names: [String]) -> (remove: [String], add: [(id: String, name: String)]) {
        let ids = taskIds(for: names)
        let wanted = Set(ids.values)
        let have = Set(existingIds)
        let remove = existingIds.filter { isTaskId($0) && !wanted.contains($0) }
        let add = names.compactMap { n in ids[n].flatMap { have.contains($0) ? nil : (id: $0, name: n) } }
        return (remove, add)
    }

    /// Second line of the card: `Hermes · profile`, or `Hermes · host` for the default profile.
    static func subtitle(profile: String, baseURL: String) -> String {
        let p = profile.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty, p.lowercased() != "default" { return "Hermes · " + p }
        if let host = URL(string: baseURL)?.host, !host.isEmpty { return "Hermes · " + host }
        return "Hermes"
    }
}

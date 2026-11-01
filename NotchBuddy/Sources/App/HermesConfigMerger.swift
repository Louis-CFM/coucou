import Foundation

// GitHub build only, like the Hermes installer in HookServer.swift that calls it.
#if !APPSTORE
/// Merges Coucou keys into a Hermes config.yaml string without touching other settings.
///
/// Returns the merged YAML string, or nil if the file uses an unsupported structure
/// (flow maps `{…}`, YAML anchors `&`, multi-document `---`) that the line-level
/// merger cannot safely handle. Callers should surface an error with the lines
/// the user needs to add manually.
///
/// Plugin enablement (plugins.enabled) is handled by the `hermes plugins enable/disable`
/// CLI after the plugin files are written; this function only manages security.approval.
func mergedHermesConfig(_ base: String, enableApprovals: Bool) -> String? {
    // Reject structures the simple merger cannot handle safely.
    // Flow maps, anchors, and multi-document markers require a full YAML parser.
    let unsafePatterns = ["{", " &", "\n---"]
    for p in unsafePatterns where base.contains(p) {
        return nil
    }

    var lines = base.components(separatedBy: "\n")

    // Detect file indentation: look for the first indented line and count spaces.
    let indent: Int = {
        for line in lines {
            let leading = line.prefix(while: { $0 == " " }).count
            if leading > 0 && leading <= 8 { return leading }
        }
        return 2  // default
    }()
    let ind  = String(repeating: " ", count: indent)         // e.g. "  " (2) or "    " (4)
    let ind2 = String(repeating: " ", count: indent * 2)     // one extra level

    // Returns the index of the first top-level section header line matching `key`.
    // Top-level = no leading spaces, ends with `:` (optionally with trailing space/comment).
    func topLevelIndex(key: String) -> Int? {
        lines.firstIndex { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix(" ") && !line.hasPrefix("\t") else { return false }
            return t == "\(key):" || t.hasPrefix("\(key):")
        }
    }

    // Returns the range of lines that belong to a top-level section (from its header to
    // just before the next top-level section, or the end of the array).
    func sectionRange(from sectionIdx: Int) -> Range<Int> {
        var end = sectionIdx + 1
        while end < lines.count {
            let l = lines[end]
            // A new top-level key: not blank, not a comment, no leading whitespace
            if !l.isEmpty && !l.hasPrefix("#") && !l.hasPrefix(" ") && !l.hasPrefix("\t") {
                break
            }
            end += 1
        }
        return sectionIdx ..< end
    }

    // --- security.approval ---
    let transportLine = "\(ind2)transport: coucou"
    let fallbackLine  = "\(ind2)transport_fallback: builtin"

    func ensureApprovalTransport() {
        if let secIdx = topLevelIndex(key: "security") {
            let secRange = sectionRange(from: secIdx)
            // Look for approval: within the security section (must be indented)
            if let approvalIdx = (secRange.lowerBound + 1 ..< secRange.upperBound)
                .first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("approval:") }) {
                // approval: block exists — update or add transport keys within it
                let approvalRange = sectionRange(from: approvalIdx)
                var hasTransport = false
                var hasFallback  = false
                for i in (approvalRange.lowerBound + 1 ..< approvalRange.upperBound) {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("transport:") && !t.hasPrefix("transport_fallback") {
                        lines[i] = transportLine; hasTransport = true
                    } else if t.hasPrefix("transport_fallback:") {
                        lines[i] = fallbackLine; hasFallback = true
                    }
                }
                let insertAt = approvalRange.lowerBound + 1
                if !hasFallback  { lines.insert(fallbackLine,  at: insertAt) }
                if !hasTransport { lines.insert(transportLine, at: insertAt) }
            } else {
                // No approval: key — insert right after security:
                let insertAt = secIdx + 1
                lines.insert("\(ind)approval:", at: insertAt)
                lines.insert(transportLine,     at: insertAt + 1)
                lines.insert(fallbackLine,      at: insertAt + 2)
            }
        } else {
            // No security: section — append
            if lines.last != "" { lines.append("") }
            lines.append("security:")
            lines.append("\(ind)approval:")
            lines.append(transportLine)
            lines.append(fallbackLine)
        }
    }

    func removeApprovalTransport() {
        // Only remove exact Coucou-written transport keys; don't touch unrelated keys.
        lines.removeAll { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t == "transport: coucou" || t == "transport_fallback: builtin"
        }
    }

    // --- plugins.enabled ---
    // Note: actual plugin enable/disable is done via `hermes plugins enable/disable coucou`
    // CLI after writing/removing the plugin files. This block ensures the preview
    // shows the complete intended state of config.yaml.
    func ensureCoucouPlugin() {
        // "Already present" = coucou in the plugins.enabled list specifically.
        // Check by finding plugins: section first, then enabled: sub-key within it.
        if let pluginsIdx = topLevelIndex(key: "plugins") {
            let pluginsRange = sectionRange(from: pluginsIdx)
            // Find enabled: within the plugins section
            if let enabledIdx = (pluginsRange.lowerBound + 1 ..< pluginsRange.upperBound)
                .first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("enabled:") }) {
                let enabledLine = lines[enabledIdx]
                let trimmed = enabledLine.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("[") && trimmed.contains("]") {
                    // Inline list: enabled: [x, y]  or  enabled: []
                    if trimmed.contains("coucou") { return }   // already present
                    if trimmed == "enabled: []" || trimmed == "enabled:[]" {
                        // Empty inline list → expand to block entry
                        let prefix = enabledLine.prefix(while: { $0 == " " })
                        lines[enabledIdx] = "\(prefix)enabled:"
                        lines.insert("\(prefix)\(ind)- coucou", at: enabledIdx + 1)
                    } else {
                        lines[enabledIdx] = enabledLine.replacingOccurrences(of: "]", with: ", coucou]")
                    }
                } else {
                    // Block list — check if coucou is already a child of this enabled:
                    let enabledRange = sectionRange(from: enabledIdx)
                    let alreadyPresent = (enabledRange.lowerBound + 1 ..< enabledRange.upperBound)
                        .contains { lines[$0].trimmingCharacters(in: .whitespaces) == "- coucou" }
                    if alreadyPresent { return }
                    // Insert after enabled:
                    let prefix = enabledLine.prefix(while: { $0 == " " })
                    lines.insert("\(prefix)\(ind)- coucou", at: enabledIdx + 1)
                }
            } else {
                // No enabled: key under plugins: — insert after plugins:
                lines.insert("\(ind)enabled:", at: pluginsIdx + 1)
                lines.insert("\(ind)\(ind)- coucou", at: pluginsIdx + 2)
            }
        } else {
            // No plugins: section — append
            if lines.last != "" { lines.append("") }
            lines.append("plugins:")
            lines.append("\(ind)enabled:")
            lines.append("\(ind)\(ind)- coucou")
        }
    }

    func removeCoucouPlugin() {
        // Remove the `- coucou` entry from plugins.enabled only.
        // If that leaves enabled: with no entries, leave the key in place (don't remove it).
        guard let pluginsIdx = topLevelIndex(key: "plugins") else { return }
        let pluginsRange = sectionRange(from: pluginsIdx)
        guard let enabledIdx = (pluginsRange.lowerBound + 1 ..< pluginsRange.upperBound)
            .first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("enabled:") })
        else { return }
        let enabledLine = lines[enabledIdx]
        let trimmed = enabledLine.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("[") && trimmed.contains("]") {
            // Inline list: remove coucou from it
            let cleaned = trimmed
                .replacingOccurrences(of: ", coucou", with: "")
                .replacingOccurrences(of: "coucou, ", with: "")
                .replacingOccurrences(of: "coucou",   with: "")
            let prefix = enabledLine.prefix(while: { $0 == " " })
            lines[enabledIdx] = "\(prefix)\(cleaned)"
        } else {
            // Block list: remove the `- coucou` entry
            let enabledRange = sectionRange(from: enabledIdx)
            // Collect indices to remove first, then remove in reverse to preserve indices.
            let toRemove = (enabledRange.lowerBound + 1 ..< enabledRange.upperBound)
                .filter { lines[$0].trimmingCharacters(in: .whitespaces) == "- coucou" }
            for i in toRemove.reversed() { lines.remove(at: i) }
        }
    }

    ensureCoucouPlugin()
    if enableApprovals { ensureApprovalTransport() } else { removeApprovalTransport() }
    return lines.joined(separator: "\n")
}
#endif

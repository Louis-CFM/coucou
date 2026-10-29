import Foundation

// MARK: - AgyPermissionRules
// Antigravity's own `command(...)` rules, read from its config files, so the notch only asks
// about the shell commands Antigravity has no rule for (Settings → Antigravity → Approve
// commands from the notch).
//
// This never allows anything. A verdict only decides whether Coucou shows a card:
// - `.allowed` / `.denied`: no card, the hook answers "ask" and Antigravity applies its rule.
// - `.unknown`: the card shows, and only a click on Allow lets the command run.
// Both mistakes are safe: a command wrongly read as allowed gets Antigravity's own prompt,
// one wrongly read as new gets a card it did not need.
// Pure Foundation, no AppKit: tested by scripts/test-agy-permissions.sh.

struct AgyPermissionRules: Equatable, Sendable {
    /// The text inside each `command(...)` rule.
    private(set) var allow: [String] = []
    private(set) var deny: [String] = []

    enum Verdict: Equatable, Sendable { case allowed, denied, unknown }

    init(allow: [String] = [], deny: [String] = []) {
        self.allow = allow
        self.deny = deny
    }

    /// Adds the `command(...)` entries of a grants object: `{"allow": [...], "deny": [...]}`.
    /// Other rule kinds (read_file, mcp, read_url…) do not apply to shell commands.
    mutating func add(grants: [String: Any]) {
        allow += Self.commandRules(grants["allow"] as? [String] ?? [])
        deny += Self.commandRules(grants["deny"] as? [String] ?? [])
    }

    /// What Antigravity's rules say about `command`.
    func verdict(for command: String) -> Verdict {
        guard let parsed = Self.parse(command), !parsed.segments.isEmpty else { return .unknown }
        let denyRules = deny.compactMap(Self.parse)
        let allowRules = allow.compactMap(Self.parse)
        // A deny rule wins: Antigravity blocks the command itself, no card is needed.
        for rule in denyRules where Self.matches(rule, parsed) { return .denied }
        // A chained command saved as one rule ("git fetch && git rebase") matches exactly.
        if allowRules.contains(where: { $0.segments.count > 1 && $0.segments == parsed.segments }) {
            return .allowed
        }
        // A command run inside $(…) or backticks is hidden from the rules below.
        if parsed.hasSubstitution {
            return allowRules.contains { $0.segments == parsed.segments } ? .allowed : .unknown
        }
        let everyPartAllowed = parsed.segments.allSatisfy { segment in
            allowRules.contains { $0.segments.count == 1 && Self.hasPrefix(segment, $0.segments[0]) }
        }
        return everyPartAllowed ? .allowed : .unknown
    }

    // MARK: Matching

    /// A rule's words start every part (single-part rule) or match the whole chain.
    private static func matches(_ rule: Parsed, _ command: Parsed) -> Bool {
        if rule.segments.count > 1 { return rule.segments == command.segments }
        guard let words = rule.segments.first else { return false }
        return command.segments.contains { hasPrefix($0, words) }
    }

    /// True when `segment` starts with every word of `words`. A rule with no words
    /// (`command()`, `command(   )`) matches nothing, as in Antigravity.
    private static func hasPrefix(_ segment: [String], _ words: [String]) -> Bool {
        !words.isEmpty && segment.count >= words.count && Array(segment.prefix(words.count)) == words
    }

    /// `["command(git log)", "mcp(x/y)"]` → `["git log"]`.
    static func commandRules(_ entries: [String]) -> [String] {
        entries.compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("command("), trimmed.hasSuffix(")") else { return nil }
            return String(trimmed.dropFirst("command(".count).dropLast())
        }
    }

    // MARK: Shell words

    struct Parsed: Equatable, Sendable {
        /// Each part of the command line (split on && || ; | & and new lines), as words.
        var segments: [[String]]
        /// The line runs another command through $(…) or backticks.
        var hasSubstitution: Bool
    }

    /// Splits a command line into parts and words, the way a POSIX shell reads quotes
    /// and backslashes. Nil when a quote is left open: the line cannot be read reliably.
    static func parse(_ line: String) -> Parsed? {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var substitution = false
        var quote: Character? = nil
        var chars = Array(line)
        chars.append(" ")
        var i = 0

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }

        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q {
                    quote = nil
                } else if q == "\"", c == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                    word.append(chars[i + 1])
                    i += 1
                } else {
                    if q == "\"", c == "`" || (c == "$" && i + 1 < chars.count && chars[i + 1] == "(") {
                        substitution = true
                    }
                    word.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                inWord = true
            case "\\":
                if i + 1 < chars.count, chars[i + 1] != "\n" { word.append(chars[i + 1]); inWord = true }
                i += 1
            case " ", "\t":
                endWord()
            case "\n", "\r", ";":
                endSegment()
            case "&" where (inWord && (word.hasSuffix(">") || word.hasSuffix("<")))
                        || (i + 1 < chars.count && chars[i + 1] == ">"):
                // A redirection (2>&1, >&2, &>file), not a separator.
                word.append(c)
                inWord = true
            case "&", "|":
                // && || & | all end the part; a doubled operator is one separator.
                if i + 1 < chars.count, chars[i + 1] == c { i += 1 }
                endSegment()
            case "`":
                substitution = true
                word.append(c)
                inWord = true
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                substitution = true
                word.append(c)
                inWord = true
            default:
                word.append(c)
                inWord = true
            }
            i += 1
        }
        guard quote == nil else { return nil }
        endSegment()
        return Parsed(segments: segments, hasSubstitution: substitution)
    }

    // MARK: Loading Antigravity's files

    /// The rules that apply to a session working in `cwd`: the CLI's settings, the shared
    /// global grants, and the grants of the Antigravity project(s) holding `cwd` (or of
    /// "Outside of Project" when none does). Missing or unreadable files add nothing.
    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     cwd: String) -> AgyPermissionRules {
        var rules = AgyPermissionRules()
        let gemini = home.appendingPathComponent(".gemini")
        if let settings = readObject(gemini.appendingPathComponent("antigravity-cli/settings.json")),
           let permissions = settings["permissions"] as? [String: Any] {
            rules.add(grants: permissions)
        }
        if let config = readObject(gemini.appendingPathComponent("config/config.json")),
           let user = config["userSettings"] as? [String: Any],
           let grants = user["globalPermissionGrants"] as? [String: Any] {
            rules.add(grants: grants)
        }
        let projectsDir = gemini.appendingPathComponent("config/projects")
        let files = (try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        var inProject = false
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "json" && file.lastPathComponent != "outside-of-project.json" {
            guard let project = readObject(file),
                  projectFolders(project).contains(where: { folder($0, contains: cwd) }) else { continue }
            inProject = true
            rules.add(grants: projectGrants(project))
        }
        if !inProject, let outside = readObject(projectsDir.appendingPathComponent("outside-of-project.json")) {
            rules.add(grants: projectGrants(outside))
        }
        return rules
    }

    /// Folder paths of an Antigravity project file (`projectResources.resources[]`).
    static func projectFolders(_ project: [String: Any]) -> [String] {
        let resources = (project["projectResources"] as? [String: Any])?["resources"] as? [[String: Any]] ?? []
        return resources.compactMap { resource in
            let uri = resource["folderUri"] as? String
                ?? (resource["gitFolder"] as? [String: Any])?["folderUri"] as? String
            guard let uri, let url = URL(string: uri), url.isFileURL else { return nil }
            return url.path
        }
    }

    /// `permissionGrants.permissionGrants` (current files) or `permissionGrants` (older ones).
    static func projectGrants(_ project: [String: Any]) -> [String: Any] {
        let outer = project["permissionGrants"] as? [String: Any] ?? [:]
        return outer["permissionGrants"] as? [String: Any] ?? outer
    }

    static func folder(_ folder: String, contains cwd: String) -> Bool {
        let root = (folder as NSString).standardizingPath
        let path = (cwd as NSString).standardizingPath
        guard !root.isEmpty, root != "/", !path.isEmpty else { return false }
        return path == root || path.hasPrefix(root + "/")
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

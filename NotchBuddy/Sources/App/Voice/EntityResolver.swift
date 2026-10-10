#if !APPSTORE
import Foundation

// MARK: - EntityResolver

/// Fuzzy-matches a voice entity name against a pill list.
/// Resolution order: aliases → exact match → word-match → Levenshtein ≤ 2.
/// No AppKit.
enum EntityResolver {

    // MARK: - Aliases

    /// Fixed aliases for names that don't appear in pill names verbatim.
    /// Key: normalised alias. Value: pill id.
    static let aliases: [String: String] = [
        // VS Code pill is the Claude Code integration
        "claude":               "integration_claude",
        "claude code":          "integration_claude",
        // Agents
        "gemini":               "agent_gemini",
        "copilot":              "agent_copilot",
        "muse":                 "agent_muse",
        "hermes":               "agent_hermes",
        "amp":                  "agent_amp",
        "opencode":             "agent_opencode",
        "antigravity":          "agent_antigravity",
        "codex":                "agent_codex",
        "claude desktop":       "agent_claude-desktop",
        // AI
        "google":               "ai_google",
        "openai":               "ai_openai",
        "open ai":              "ai_openai",
        "ollama":               "ai_ollama",
        "lmstudio":             "ai_lmstudio",
        "anthropic":            "ai_anthropic",
        // Services
        "github":               "integration_github",
        // GitHub phonetic variants (speech recognition mishears)
        "gt":                   "integration_github",
        "g t":                  "integration_github",
        "git hub":              "integration_github",
        "jit hub":              "integration_github",
        "guitare hub":          "integration_github",
        "guitar hub":           "integration_github",
        "gitub":                "integration_github",
        "guit hub":             "integration_github",
        "vercel":               "integration_vercel",
        "notion":               "integration_notion",
        "stripe":               "integration_stripe",
        "resend":               "integration_resend",
        "n8n":                  "integration_n8n",
        "calcom":               "integration_calcom",
        "cal":                  "integration_calcom",
        "spotify":              "integration_spotify",
        "apple music":          "integration_music",
        "music":                "integration_music",
        "musique":              "integration_music",
    ]

    // MARK: - Public API

    /// Resolve `query` to a pill id from `pills`.
    /// Pass `category` to restrict to workspace pills (for main-pill commands).
    /// Returns nil when no match within tolerance, or when the match is ambiguous.
    static func resolve(
        _ query: String,
        from pills: [PillDefinition],
        category: PillCategory? = nil
    ) -> String? {
        let q = IntentParser.normalise(query)
        var pool = pills
        if let cat = category { pool = pool.filter { $0.category == cat } }
        guard !pool.isEmpty, !q.isEmpty else { return nil }

        // 1. Alias table (handles "claude", "gemini", "google", etc.)
        if let aliasId = aliases[q] {
            if pool.contains(where: { $0.id == aliasId }) { return aliasId }
        }

        // 2. Exact name match (case-insensitive + diacritic-insensitive)
        if let exact = pool.first(where: { IntentParser.normalise($0.name) == q }) {
            return exact.id
        }

        // 3. Word-match: q is a complete word inside the pill's normalised name
        //    e.g. "gemini" matches "gemini cli", "copilot" matches "copilot cli"
        let wordMatches = pool.filter { def in
            let nameWords = IntentParser.normalise(def.name).split(separator: " ").map(String.init)
            return nameWords.contains(q)
        }
        if wordMatches.count == 1 { return wordMatches[0].id }
        if wordMatches.count > 1  { return nil }   // ambiguous

        // 4. Levenshtein ≤ 2 (≤ 1 for short queries)
        var best:       (id: String, dist: Int)?
        var secondBest: (id: String, dist: Int)?

        for def in pool {
            let target = IntentParser.normalise(def.name)
            let d = levenshtein(q, target)
            if d < (best?.dist ?? Int.max) {
                secondBest = best
                best = (def.id, d)
            } else if d < (secondBest?.dist ?? Int.max) {
                secondBest = (def.id, d)
            }
        }

        guard let winner = best else { return nil }

        let tolerance = q.count <= 4 ? 1 : 2
        guard winner.dist <= tolerance else { return nil }
        if let runner = secondBest, runner.dist <= tolerance { return nil }

        return winner.id
    }

    // MARK: - Levenshtein distance

    /// Standard Wagner–Fischer DP. Operates on Character arrays.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let ac = Array(a), bc = Array(b)
        let m = ac.count, n = bc.count
        if m == 0 { return n }
        if n == 0 { return m }
        var row = Array(0...n)
        for i in 1...m {
            var prev = row[0]
            row[0] = i
            for j in 1...n {
                let temp = row[j]
                row[j] = ac[i-1] == bc[j-1]
                    ? prev
                    : Swift.min(prev, Swift.min(row[j], row[j-1])) + 1
                prev = temp
            }
        }
        return row[n]
    }
}
#endif

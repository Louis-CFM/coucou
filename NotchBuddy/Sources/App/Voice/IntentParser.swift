#if !APPSTORE
import Foundation

// MARK: - IntentParser

/// Parses a raw voice transcript into a VoiceIntent.
/// Pure Foundation — no AppKit, no AppState, no I/O.
/// Standalone compilable (used directly in test scripts via `swiftc`).
enum IntentParser {

    // MARK: - Public API

    static func parse(_ raw: String, pills: [PillDefinition] = []) -> VoiceIntent {
        let norm  = normalise(raw)
        let words = norm.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return .unknown }

        // rawWords: same splits as normalise but no diacritics strip, no letter filter, original case
        let rawWords0 = buildRawWords(raw)
        // defilter both arrays in parallel: ma→la, mon→le, strip filler words
        var (fwords, frawWords) = defilter(words, rawWords: rawWords0)
        guard !fwords.isEmpty else { return .unknown }

        // ── 0. Strip a trailing location: "… dans les pilules", "… dans le notch" ──
        (fwords, frawWords) = stripTrailingLocation(fwords, rawWords: frawWords)
        guard !fwords.isEmpty else { return .unknown }

        // ── 0a. Strip politeness prefixes from the start ─────────────────────
        //    "tu peux", "est-ce que tu peux", "peux-tu", "can you", etc.
        for prefix in politenessPrefixes {
            if fwords.starts(with: prefix) {
                fwords    = Array(fwords[prefix.count...])
                frawWords = Array(frawWords[min(prefix.count, frawWords.count)...])
                break
            }
        }
        guard !fwords.isEmpty else { return .unknown }

        // ── 0b. Map infinitives → imperative forms ────────────────────────────
        //    "mettre" → "mets", "lancer" → "lance", "ajouter" → "ajoute", …
        fwords = fwords.map { infinitiveMap[$0] ?? $0 }

        // ── 1. Explicit music-only patterns ──────────────────────────────────
        if matchesAny(fwords, in: pausePrefixes)   { return .musicPause }
        if matchesAny(fwords, in: nextPrefixes)    { return .musicNext }
        if matchesAny(fwords, in: prevPrefixes)    { return .musicPrevious }
        if matchesAny(fwords, in: volUpPrefixes)   { return .musicVolumeUp }
        if matchesAny(fwords, in: volDownPrefixes) { return .musicVolumeDown }

        // ── 2. Volume set: "volume à 50" / "set volume 50" ──────────────────
        if let pct = extractVolume(fwords) { return .musicSetVolume(pct) }

        // ── 3. Explicit music-play target: "… sur Spotify" / "… on Spotify" ─
        if let target = extractMusicPlayTarget(fwords, pills: pills) {
            return .musicPlay(target: target)
        }

        // ── 4. "principale/principal" keyword → pillSetMain ──────────────────
        //    "passe la pilule principale sur Cursor"
        if fwords.contains("principale") || fwords.contains("principal") {
            if let surIdx = fwords.firstIndex(of: "sur"), surIdx + 1 < fwords.count {
                let entity = fwords[(surIdx+1)...].joined(separator: " ")
                let clean  = stripArticles(entity)
                if !clean.isEmpty,
                   let id = EntityResolver.resolve(clean, from: pills, category: .workspace) {
                    return .pillSetMain(id: id)
                }
            }
            // "change la pilule principale pour Codex" / "pilule principale c est X"
            for sep in ["pour", "c est", "est"] {
                let sepWords = sep.split(separator: " ").map(String.init)
                if let sepStart = indexOfSequence(sepWords, in: fwords) {
                    let entity = fwords[(sepStart + sepWords.count)...].joined(separator: " ")
                    let clean  = stripArticles(entity)
                    if !clean.isEmpty,
                       let id = EntityResolver.resolve(clean, from: pills, category: .workspace) {
                        return .pillSetMain(id: id)
                    }
                }
            }
        }
        // "mets Cursor en principal[e]"
        if let enIdx = fwords.indices.dropLast().first(where: {
            fwords[$0] == "en" && (fwords[$0+1] == "principal" || fwords[$0+1] == "principale")
        }), enIdx > 0 {
            let entity = fwords[1..<enIdx].joined(separator: " ")
            let clean  = stripArticles(entity)
            if !clean.isEmpty,
               let id = EntityResolver.resolve(clean, from: pills, category: .workspace) {
                return .pillSetMain(id: id)
            }
        }
        // "Cursor comme pilule principale"
        if fwords.contains("comme") && (fwords.contains("principale") || fwords.contains("principal")) {
            if let comIdx = fwords.firstIndex(of: "comme"), comIdx > 0 {
                let entity = fwords[0..<comIdx].joined(separator: " ")
                let clean  = stripArticles(entity)
                if !clean.isEmpty,
                   let id = EntityResolver.resolve(clean, from: pills, category: .workspace) {
                    return .pillSetMain(id: id)
                }
            }
        }

        // ── 5. pillReplace: "remplace n8n par github" ────────────────────────
        if let (old, new) = extractReplace(fwords, pills: pills) {
            return .pillReplace(old: old, new: new)
        }

        // ── 6. pillOnly: "garde seulement GitHub et Vercel" ──────────────────
        if let ids = extractOnly(fwords, pills: pills) {
            return .pillOnly(ids)
        }

        // ── 7. Playlist triggers (before generic music so "mets la playlist…" wins) ─
        if let match = extractAfter(fwords, rawWords: frawWords, triggers: playlistTriggers) {
            let clean    = stripArticles(match.norm)
            let cleanRaw = stripArticlesRaw(match.raw)
            if !clean.isEmpty {
                return .musicPlayPlaylist(name: cleanRaw.isEmpty ? clean : cleanRaw)
            }
        }

        // ── 8. pillMain triggers (setMain-only verbs) ────────────────────────
        if let match = extractAfter(fwords, rawWords: frawWords, triggers: pillMainTriggers) {
            let clean = stripArticles(match.norm)
            if !clean.isEmpty {
                // "pilule" keyword present but no "principale" → pillAdd (handled in step 9)
                if !fwords.contains("principale") && !fwords.contains("principal") {
                    // Check if word "pilule" or "pill" is in the original (before trigger)
                    // The trigger itself consumed "utilise/use/passe sur" etc. so "pilule" before trigger → pillAdd
                }
                let id = EntityResolver.resolve(clean, from: pills, category: .workspace)
                return id != nil ? .pillSetMain(id: id!) : .unknown
            }
        }

        // ── 9. Ambiguous triggers: pill-first, then music ────────────────────
        if let match = extractAfter(fwords, rawWords: frawWords, triggers: musicPillTriggers) {
            // Detect "pilule" keyword without "principale" → force pillAdd path
            let hasPilule   = fwords.contains("pilule") || fwords.contains("pill")
            let hasMainKeyword = fwords.contains("principale") || fwords.contains("principal")
            let clean    = stripArticles(match.norm)
            let cleanRaw = stripArticlesRaw(match.raw)
            if !clean.isEmpty {
                // Check for multi-pill: "X et Y"
                let parts = splitByConjunction(clean)
                if parts.count >= 2 {
                    let ids = parts.compactMap { part -> String? in
                        let p = stripArticles(part)
                        return p.isEmpty ? nil : EntityResolver.resolve(p, from: pills)
                    }
                    if ids.count >= 2 { return .pillAddMultiple(ids: ids) }
                }
                // Generic music word → musicPlay(nil) FIRST (before service-pill check so
                // "musique" alias → integration_music doesn't force an appleMusic target)
                if musicGenericWords.contains(clean) { return .musicPlay(target: nil) }
                // Music service pills → musicPlay with explicit target
                if let id = EntityResolver.resolve(clean, from: pills),
                   musicServicePillIds.contains(id) {
                    let target: MusicTarget = id == "integration_spotify" ? .spotify : .appleMusic
                    return .musicPlay(target: target)
                }
                // "pilule" without "principale" → pillAdd (skip workspace check)
                if hasPilule && !hasMainKeyword {
                    if let id = EntityResolver.resolve(clean, from: pills) {
                        return .pillAdd(id: id)
                    }
                    return .unknown
                }
                // Workspace pill → pillSetMain
                if let id = EntityResolver.resolve(clean, from: pills, category: .workspace) {
                    return .pillSetMain(id: id)
                }
                // Other pill → pillAdd
                if let id = EntityResolver.resolve(clean, from: pills) {
                    return .pillAdd(id: id)
                }
                // Not a pill, not generic → search (title or artist) with original text
                let name = cleanRaw.isEmpty ? clean : cleanRaw
                return .musicPlaySearch(name: name)
            }
        }

        // ── 10. pillRemove triggers ───────────────────────────────────────────
        if let match = extractAfter(fwords, rawWords: frawWords, triggers: pillRemoveTriggers) {
            let clean = stripArticles(match.norm)
            if !clean.isEmpty {
                // Multi-pill: "X et Y"
                let parts = splitByConjunction(clean)
                if parts.count >= 2 {
                    let ids = parts.compactMap { part -> String? in
                        let p = stripArticles(part)
                        return p.isEmpty ? nil : EntityResolver.resolve(p, from: pills)
                    }
                    if ids.count >= 2 { return .pillRemoveMultiple(ids: ids) }
                }
                if let id = EntityResolver.resolve(clean, from: pills) { return .pillRemove(id: id) }
                return .unknown
            }
        }

        // ── 11. pillAdd-only triggers (affiche, show, montre, enable) ─────────
        if let match = extractAfter(fwords, rawWords: frawWords, triggers: pillAddOnlyTriggers) {
            let clean = stripArticles(match.norm)
            if !clean.isEmpty {
                // Multi-pill: "X et Y"
                let parts = splitByConjunction(clean)
                if parts.count >= 2 {
                    let ids = parts.compactMap { part -> String? in
                        let p = stripArticles(part)
                        return p.isEmpty ? nil : EntityResolver.resolve(p, from: pills)
                    }
                    if ids.count >= 2 { return .pillAddMultiple(ids: ids) }
                }
                if let id = EntityResolver.resolve(clean, from: pills) { return .pillAdd(id: id) }
                return .unknown
            }
        }

        // ── 12. Generic musicPlay phrases (bare / multi-word) ─────────────────
        if matchesAny(fwords, in: playPrefixes) { return .musicPlay(target: nil) }

        // Bare single music verb
        if fwords.count == 1, let v = fwords.first, bareMusicVerbs.contains(v) {
            return .musicPlay(target: nil)
        }

        return .unknown
    }

    // MARK: - Multi-action splitting

    /// Try to parse `raw` as two or more sequential intents separated by "et/puis/ensuite/and/then".
    /// Returns nil if fewer than 2 valid (non-.unknown) intents can be extracted — the caller
    /// should fall back to single-intent `parse()` in that case.
    ///
    /// Safe against single-intent uses of conjunctions: if any part produces `.unknown`,
    /// the whole call returns nil (e.g. "mets Gemini et Cursor" splits to ["mets Gemini", "Cursor"];
    /// "Cursor" alone is unknown → falls back to the single-intent parser which returns
    /// `.pillAddMultiple`).
    static func parseMultiAction(_ raw: String, pills: [PillDefinition] = []) -> [VoiceIntent]? {
        let conjunctions: Set<String> = ["et", "puis", "ensuite", "and", "then"]

        // 1. Commas (before normalise, which strips punctuation).
        let commaParts = raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 2. Action verbs: "ajoute Stripe enlève Vercel" → two pieces, no "et" needed.
        //    Words before the first verb stay with it ("tu peux enlever GitHub").
        let verbPieces = commaParts.flatMap { splitOnActionVerbs($0) }

        // 3. Inside a piece, split on conjunctions when every part parses on its own
        //    ("pause et ajoute Notion", "mets du Daft Punk et monte le son"). Otherwise the
        //    piece stays whole ("ajoute Notion et Stripe" = one multi-add, "mets du Simon
        //    et Garfunkel" = one search), unless the whole is a music search swallowing a
        //    second command.
        var intents: [VoiceIntent] = []
        for piece in verbPieces {
            let words = normalise(piece).split(separator: " ").map(String.init)
            var parts: [[String]] = []
            var cur: [String] = []
            for w in words {
                if conjunctions.contains(w) {
                    if !cur.isEmpty { parts.append(cur); cur = [] }
                } else { cur.append(w) }
            }
            if !cur.isEmpty { parts.append(cur) }
            let sub = parts.map { parse($0.joined(separator: " "), pills: pills) }
            if parts.count >= 2, sub.allSatisfy({ $0 != .unknown }) {
                intents.append(contentsOf: sub)
                continue
            }
            let whole = parse(piece, pills: pills)
            guard whole != .unknown else { return nil }
            intents.append(whole)
        }
        return intents.count >= 2 ? intents : nil
    }

    /// Action verbs that start a new action inside one sentence (normalised forms,
    /// imperative and infinitive, FR + EN).
    static let segmentVerbs: Set<String> = [
        "ajoute", "ajouter", "rajoute", "rajouter", "mets", "met", "mettre", "remets", "remettre",
        "active", "activer", "enleve", "enlever", "retire", "retirer", "supprime", "supprimer",
        "vire", "virer", "degage", "degager", "desactive", "desactiver", "cache", "cacher",
        "lance", "lancer", "joue", "jouer",
        "add", "remove", "put", "enable", "disable", "play",
    ]

    /// "ajoute Stripe enleve Vercel" → ["ajoute Stripe", "enleve Vercel"].
    /// A new segment starts at an action verb only when the current one already has a verb.
    static func splitOnActionVerbs(_ segment: String) -> [String] {
        let words = segment.split(separator: " ").map(String.init)
        var parts: [[String]] = []
        var cur: [String] = []
        var curHasVerb = false
        for w in words {
            let isVerb = segmentVerbs.contains(normalise(w))
            if isVerb && curHasVerb {
                parts.append(cur); cur = []; curHasVerb = false
            }
            cur.append(w)
            if isVerb { curHasVerb = true }
        }
        if !cur.isEmpty { parts.append(cur) }
        // "mets Gemini et | enlève GitHub": the joining word stays out of both pieces.
        let joins: Set<String> = ["et", "puis", "ensuite", "and", "then"]
        return parts.compactMap { p in
            var p = p
            while let l = p.last,  joins.contains(normalise(l)) { p.removeLast() }
            while let f = p.first, joins.contains(normalise(f)) { p.removeFirst() }
            return p.isEmpty ? nil : p.joined(separator: " ")
        }
    }

    /// Drops a trailing "dans les pilules" / "dans le notch" / "dans la barre" (after defilter,
    /// so "piles" is already gone and "mes" is already "les").
    private static func stripTrailingLocation(
        _ words: [String], rawWords: [String]
    ) -> ([String], [String]) {
        guard let i = words.lastIndex(of: "dans"), i > 0 else { return (words, rawWords) }
        let tail = Array(words[(i + 1)...])
        let articles: Set<String> = ["les", "la", "le", "l"]
        let places:   Set<String> = ["pilules", "pilule", "notch", "encoche", "barre", "liste"]
        let ok = (tail.count == 1 && articles.contains(tail[0]))
              || (tail.count == 2 && articles.contains(tail[0]) && places.contains(tail[1]))
        guard ok else { return (words, rawWords) }
        return (Array(words[..<i]), Array(rawWords[..<min(i, rawWords.count)]))
    }

    // MARK: - Normalisation

    static func normalise(_ s: String) -> String {
        var r = s.lowercased()
        r = r.replacingOccurrences(of: "'",       with: " ")
        r = r.replacingOccurrences(of: "\u{2019}", with: " ")
        r = r.replacingOccurrences(of: "-",       with: " ")
        r = r.folding(options: .diacriticInsensitive, locale: nil)
        r = r.filter { $0.isLetter || $0.isNumber || $0 == " " }
        return r.split(separator: " ").joined(separator: " ")
    }

    /// Build rawWords: original casing + accents, split on apostrophes/hyphens,
    /// filter words that have no letter or digit (pure punctuation).
    private static func buildRawWords(_ raw: String) -> [String] {
        var r = raw
        r = r.replacingOccurrences(of: "'",       with: " ")
        r = r.replacingOccurrences(of: "\u{2019}", with: " ")
        r = r.replacingOccurrences(of: "-",        with: " ")
        return r.split(separator: " ").map(String.init).filter { w in
            !w.isEmpty && w.contains(where: { $0.isLetter || $0.isNumber })
        }
    }

    /// Apply filler-word removal and article normalisation to both arrays in parallel.
    /// Removes: "un", "peu", "s", "il", "te", "plait", "moi" (filler words).
    /// Replaces: "ma"→"la", "mon"→"le", "mes"→"les" (possessive → definite article).
    private static func defilter(
        _ words: [String], rawWords: [String]
    ) -> ([String], [String]) {
        // "truc", "chose", "machin", "bidule" = placeholder words used before an entity name
        // e.g. "mets le truc Gemini" → "mets Gemini"
        let fillers:  Set<String>    = ["un", "peu", "s", "il", "te", "plait", "moi",
                                        "truc", "chose", "machin", "bidule",
                                        "pile", "piles", "aussi", "stp"]
        let synonyms: [String: String] = ["ma": "la", "mon": "le", "mes": "les"]
        var fw: [String] = []
        var fr: [String] = []
        for (w, r) in zip(words, rawWords) {
            if let rep = synonyms[w] {
                fw.append(rep); fr.append(r)
            } else if !fillers.contains(w) {
                fw.append(w); fr.append(r)
            }
        }
        return (fw, fr)
    }

    // MARK: - Pattern helpers

    private static func matchesAny(_ words: [String], in table: [[String]]) -> Bool {
        table.contains { contains(words, sequence: $0) }
    }

    private static func contains(_ words: [String], sequence seq: [String]) -> Bool {
        guard seq.count <= words.count else { return false }
        for i in 0...(words.count - seq.count) {
            if words[i..<(i + seq.count)].elementsEqual(seq) { return true }
        }
        return false
    }

    /// Return (normTail, rawTail) after the first matching trigger, longest first.
    private static func extractAfter(
        _ words: [String],
        rawWords: [String],
        triggers: [[String]]
    ) -> (norm: String, raw: String)? {
        let sorted = triggers.sorted { $0.count > $1.count }
        for trigger in sorted {
            guard trigger.count < words.count else { continue }
            for i in 0...(words.count - trigger.count) {
                if words[i..<(i + trigger.count)].elementsEqual(trigger) {
                    let norm = words[(i + trigger.count)...].joined(separator: " ")
                    let raw  = i + trigger.count < rawWords.count
                               ? rawWords[(i + trigger.count)...].joined(separator: " ")
                               : ""
                    if !norm.isEmpty { return (norm, raw) }
                }
            }
        }
        return nil
    }

    /// First index where `seq` appears as a contiguous subsequence in `words`.
    private static func indexOfSequence(_ seq: [String], in words: [String]) -> Int? {
        guard !seq.isEmpty, seq.count <= words.count else { return nil }
        for i in 0...(words.count - seq.count) {
            if words[i..<(i + seq.count)].elementsEqual(seq) { return i }
        }
        return nil
    }

    private static func stripArticles(_ name: String) -> String {
        let articles: Set<String> = ["du", "de", "la", "le", "les", "des", "l",
                                      "some", "the", "a", "an", "pilule", "pill",
                                      "pile", "piles", "ma", "mon", "mes"]
        var ws = name.split(separator: " ").map(String.init)
        while let first = ws.first, articles.contains(first) { ws.removeFirst() }
        return ws.joined(separator: " ")
    }

    /// stripArticles applied to a raw (original-casing) string by comparing lowercased.
    private static func stripArticlesRaw(_ name: String) -> String {
        let articles: Set<String> = ["du", "de", "la", "le", "les", "des", "l",
                                      "some", "the", "a", "an", "pilule", "pill",
                                      "pile", "piles", "ma", "mon", "mes"]
        var ws = name.split(separator: " ").map(String.init)
        while let first = ws.first, articles.contains(first.lowercased()) { ws.removeFirst() }
        return ws.joined(separator: " ")
    }

    /// Split entity string by "et"/"and" conjunctions.
    private static func splitByConjunction(_ name: String) -> [String] {
        let words = name.split(separator: " ").map(String.init)
        var parts: [[String]] = []
        var cur:   [String]  = []
        for w in words {
            if w == "et" || w == "and" {
                if !cur.isEmpty { parts.append(cur); cur = [] }
            } else { cur.append(w) }
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts.map { $0.joined(separator: " ") }
    }

    // MARK: - Volume extraction

    private static func extractVolume(_ words: [String]) -> Int? {
        guard words.contains("volume"),
              let numStr = words.last(where: { Int($0) != nil }),
              let pct = Int(numStr), pct >= 0, pct <= 100 else { return nil }
        guard let volIdx  = words.firstIndex(of: "volume"),
              let numIdx  = words.indices.last(where: { Int(words[$0]) != nil }),
              volIdx < numIdx else { return nil }
        return pct
    }

    // MARK: - Music target extraction: "… sur Spotify" / "… on Spotify"

    private static func extractMusicPlayTarget(
        _ words: [String], pills: [PillDefinition]
    ) -> MusicTarget? {
        for preposition in ["sur", "on"] {
            guard let idx = words.lastIndex(of: preposition), idx + 1 < words.count else { continue }
            let afterWords = Array(words[(idx+1)...])
            let entity = afterWords.joined(separator: " ")
            if let id = EntityResolver.resolve(entity, from: pills) {
                if id == "integration_spotify"  { return .spotify }
                if id == "integration_music"    { return .appleMusic }
            }
        }
        return nil
    }

    // MARK: - pillReplace extraction

    private static func extractReplace(_ words: [String], pills: [PillDefinition]) -> (String, String)? {
        let startTriggers: [[String]] = [["remplace"], ["replace"], ["echange"], ["swap"], ["change"]]
        let separators = ["par", "for", "contre", "with", "by"]
        for start in startTriggers {
            guard contains(words, sequence: start) else { continue }
            guard let startIdx = indexOfSequence(start, in: words) else { continue }
            let rest = Array(words[(startIdx + start.count)...])
            for sep in separators {
                guard let sepIdx = rest.firstIndex(of: sep), sepIdx > 0, sepIdx < rest.count - 1 else { continue }
                let e1 = stripArticles(rest[..<sepIdx].joined(separator: " "))
                let e2 = stripArticles(rest[(sepIdx+1)...].joined(separator: " "))
                if let id1 = EntityResolver.resolve(e1, from: pills),
                   let id2 = EntityResolver.resolve(e2, from: pills) {
                    return (id1, id2)
                }
            }
        }
        return nil
    }

    // MARK: - pillOnly extraction

    private static func extractOnly(_ words: [String], pills: [PillDefinition]) -> [String]? {
        let starts: [[String]] = [["garde", "seulement"], ["keep", "only"], ["garder", "seulement"]]
        for start in starts {
            guard contains(words, sequence: start) else { continue }
            let rest = Array(words[start.count...])
            var parts: [[String]] = []
            var cur:   [String]  = []
            for w in rest {
                if w == "et" || w == "and" { if !cur.isEmpty { parts.append(cur); cur = [] } }
                else { cur.append(w) }
            }
            if !cur.isEmpty { parts.append(cur) }
            var ids: [String] = []
            for part in parts {
                let clean = stripArticles(part.joined(separator: " "))
                if !clean.isEmpty, let id = EntityResolver.resolve(clean, from: pills) {
                    ids.append(id)
                }
            }
            if !ids.isEmpty { return ids }
        }
        return nil
    }

    // MARK: - Keyword tables

    /// Polite prefix sequences stripped from the START of the word array (longest first).
    private static let politenessPrefixes: [[String]] = [
        ["est", "ce", "que", "tu", "peux"],
        ["est", "ce", "que", "tu", "pourrais"],
        ["tu", "peux"],
        ["tu", "pourrais"],
        ["peux", "tu"],
        ["could", "you"],
        ["can", "you"],
        ["please"],
    ]

    /// Maps normalised infinitive forms → imperative/trigger forms.
    private static let infinitiveMap: [String: String] = [
        "mettre":      "mets",
        "lancer":      "lance",
        "jouer":       "joue",
        "ajouter":     "ajoute",
        "enlever":     "enleve",
        "retirer":     "retire",
        "supprimer":   "supprime",
        "activer":     "active",
        "desactiver":  "desactive",
        "remplacer":   "remplace",
        "garder":      "garde",
        "passer":      "passe",
        "monter":      "monte",
        "baisser":     "baisse",
        "couper":      "coupe",
        "arreter":     "arrete",
    ]

    private static let pausePrefixes: [[String]] = [
        ["pause"], ["stop"], ["stoppe"], ["coupe"],
        ["mets", "en", "pause"], ["met", "en", "pause"],
        ["arrete", "la", "musique"], ["arrete", "la", "chanson"],
        ["arrete", "la", "lecture"],
        ["arrete"],
        ["coupe", "la", "musique"],
    ]

    private static let nextPrefixes: [[String]] = [
        ["morceau", "suivant"], ["chanson", "suivante"], ["suivant"], ["prochain"],
        ["next", "track"], ["next", "song"], ["next"], ["skip"],
        ["chanson", "d", "apres"], ["d", "apres"],
        ["passe", "a", "la", "suivante"],
    ]

    private static let prevPrefixes: [[String]] = [
        ["morceau", "precedent"], ["chanson", "precedente"], ["precedent"], ["en", "arriere"],
        ["previous", "track"], ["previous", "song"], ["previous"], ["back"],
        ["remets", "la", "chanson", "d", "avant"], ["chanson", "d", "avant"],
        ["reviens", "en", "arriere"],
    ]

    private static let volUpPrefixes: [[String]] = [
        ["monte", "le", "son"], ["monte", "le", "volume"],
        ["augmente", "le", "son"], ["augmente", "le", "volume"],
        ["plus", "fort"], ["volume", "up"], ["louder"], ["turn", "up"],
    ]

    private static let volDownPrefixes: [[String]] = [
        ["baisse", "le", "son"], ["baisse", "le", "volume"],
        ["diminue", "le", "son"], ["diminue", "le", "volume"],
        ["moins", "fort"], ["volume", "down"], ["quieter"], ["turn", "down"],
    ]

    private static let playlistTriggers: [[String]] = [
        ["joue", "la", "playlist"], ["lance", "la", "playlist"],
        ["mets", "la", "playlist"], ["demarre", "la", "playlist"],
        ["play", "playlist"], ["start", "playlist"],
        ["balance", "la", "playlist"],
    ]

    // SetMain-only verbs — no fall-through to music on miss
    private static let pillMainTriggers: [[String]] = [
        ["passe", "sur"], ["change", "pour"], ["met", "sur"], ["mets", "sur"],
        ["switch", "to"], ["set", "main", "to"], ["change", "to"],
        ["utilise"], ["use"],
    ]

    // Ambiguous verbs — pill first, then music
    private static let musicPillTriggers: [[String]] = [
        ["joue"], ["play"], ["mets"], ["met"], ["lance"], ["start"],
        ["demarre"], ["balance"], ["envoie"], ["reprends"], ["resume"],
    ]

    // Pill-add-only verbs
    private static let pillAddOnlyTriggers: [[String]] = [
        ["active"], ["affiche"], ["montre"], ["rajoute"], ["ajoute"],
        ["add"], ["enable"], ["show"], ["activate"],
        ["je", "veux"], ["me", "faut"],
    ]

    private static let pillRemoveTriggers: [[String]] = [
        ["enleve"], ["supprime"], ["desactive"], ["cache"], ["retire"], ["efface"],
        ["remove"], ["disable"], ["hide"], ["delete"],
        ["vire"], ["degage"], ["enleve", "moi"], ["plus", "besoin", "de"],
    ]

    // Bare music verbs (single word → musicPlay)
    private static let bareMusicVerbs: Set<String> = [
        "joue", "lance", "play", "start", "demarre", "balance",
        "reprends", "resume",
    ]

    // Generic musicPlay nouns (entity after verb → musicPlay, not artist)
    private static let musicGenericWords: Set<String> = [
        "musique", "son", "music", "audio", "chanson", "chansons",
    ]

    // Music-service pill ids — pill detected but route to musicPlay
    private static let musicServicePillIds: Set<String> = [
        "integration_music", "integration_spotify",
    ]

    private static let playPrefixes: [[String]] = [
        ["lance", "la", "musique"], ["lance", "la", "chanson"],
        ["reprends", "la", "musique"], ["reprends"],
        ["play", "music"], ["start", "music"], ["resume", "music"], ["resume"],
        ["play", "some", "music"],
        ["balance", "de", "la", "musique"], ["balance", "la", "musique"],
        ["envoie", "de", "la", "musique"],
        ["mets", "de", "la", "musique"], ["mets", "du", "son"],
    ]
}
#endif

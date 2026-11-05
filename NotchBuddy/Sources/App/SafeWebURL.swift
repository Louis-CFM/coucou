import Foundation

/// Returns the URL only if it is a plain web link (http/https with a host). Model output
/// and API data can carry file://, smb:// or custom app schemes that would launch local apps
/// or deep links; those never reach NSWorkspace.open.
func safeWebURL(_ string: String?) -> URL? {
    guard let string,
          let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
          let host = url.host, !host.isEmpty,
          // A user or a password in front of the host makes a link read as one site and go to another.
          url.user == nil, url.password == nil else { return nil }
    return url
}

// MARK: - What a link in an agent answer shows and does

/// What a click on a link of an answer does. `open`: the destination opens. `confirm`: the label names another host
/// than the destination (or is a suspicious address), so the user is asked first. `discard`: the destination does
/// not pass `safeWebURL` (or has a host that cannot be shown), so nothing happens.
enum LinkClick: Equatable { case open, confirm, discard }

/// The host of a destination as the URL parser gives it (international hosts in their ASCII form, so a look alike
/// reads as what it is), lower case, no trailing dot. Nil when there is none.
func linkDestinationHost(_ destination: String?) -> String? {
    guard let destination,
          let host = URL(string: destination.trimmingCharacters(in: .whitespacesAndNewlines))?.host, !host.isEmpty else { return nil }
    return normalizedHost(host)
}

/// The host to show a person (tooltip, confirmation): the ASCII host of a destination that passes `safeWebURL`, and
/// only when it is made of letters, digits, dot and dash. A long host is cut from the left, the end is what counts.
func linkShownHost(_ destination: String?) -> String? {
    guard safeWebURL(destination) != nil, let host = linkDestinationHost(destination),
          host.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "." || $0 == "-") })
    else { return nil }
    return host.count > maxShownHost ? "\u{2026}" + host.suffix(maxShownHost) : host
}

private let maxShownHost = 40

private func normalizedHost(_ host: String) -> String {
    var h = host.lowercased()
    while h.hasSuffix(".") { h.removeLast() }
    return h
}

private func withoutWWW(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

// MARK: - The rule: open at once only when the text is provably plain
//
// A link is judged by its context: the text of the block around it, extended on both sides to the nearest ASCII space
// (U+0020) or newline (U+000A) and no further (a tab is not a delimiter, nor is a narrow space, a zero width character or
// another control character, so none of them can cut a host in two), at most `maxContextSide` scalars on each side and
// `maxContextScalars` in all (past that: confirm). The context is normalised with NFC. There are no exemptions and no
// list of tricks; every step below is an allow list, and what is not allowed asks.
//   B. Allowed scalars. One scalar outside this set: CONFIRM.
//      1. ASCII letters and digits. 2. Printable ASCII, U+0020 to U+007E (no tab, no other control).
//      3. Latin letters in U+00C0 to U+024F and U+1E00 to U+1EFF that NFKC leaves alone (so not U+0140, U+013F...).
//      4. Letters of categories Lu, Ll, Lt, Lo, only in the blocks of `scriptGroup` (Cyrillic, Greek, kana, Han, Hangul
//         syllables), and only in a word (a run of letters and digits) of one script group: no ASCII letter or digit, no
//         rule 3 Latin letter, no letter of another group (kana and Han may share a word). Never Lm, never a Hangul filler
//         (U+115F, U+1160, U+3164, U+FFA0). Any other block asks (Hebrew, Arabic, Thai, Armenian, Georgian...).
//      5. U+2019 U+2018 U+201C U+201D U+2014 U+2013 U+00AB U+00BB with a letter, an ASCII digit, an ASCII space or the edge
//         of the context on each side; U+2026 the same and with an ASCII space or the edge on at least one side.
//   C. A comma, semicolon or colon with a letter or digit on both sides: CONFIRM. Exceptions: digits on both sides of a comma
//      (1,5), and a colon directly before a digit (a port or a time), which goes to D.
//   D. Dots. A full stop that ends the context is sentence punctuation and is ignored, but only when the context is followed,
//      after any ASCII spaces, by the end of the block or by a scalar that is not a newline (a full stop, spaces, a newline
//      and more text is not). If another
//      full stop remains, or the context holds `//` or a colon directly before a digit, the context is DOTTED. A dotted
//      context opens only when every token (run of non space scalars) that holds a dot, `//` or a colon before a digit
//      names the destination: stripped of leading and trailing `( ) [ ] { } < > , ; ! ? " '` and one trailing full stop, it
//      is an address (optional http or https scheme, host, optional port, optional path, query or fragment) whose host is the
//      destination host (www aside). Or it is a decimal or version number (digits and full stops, 3.14, 1.2.3), which claims
//      nothing, unless it starts with an IPv4 (four parts, 0 to 255), which must be the destination host.
//   E. Anything else that passed B and C with no dotted token: OPEN.
//
// Accepted honest cost (the dialog is the price of never guessing). All of these ask: `Node.js`, `README.md`, `src/main.py`,
// `St.John`, `e.g.`, `v1.2`, `user@example.com`, `~/.zshrc`, `10:30`, `Wait...`, a text with a comma or a colon between letters
// (`a,b`), an emoji or another symbol, a curly quote around an address, an international host (`münchen.de`), a word that
// mixes ASCII and another script (`GitHub` and a Japanese letter), a word that mixes Cyrillic, Greek and East Asian letters,
// a Hebrew, Arabic, Thai, Armenian, Georgian or Hindi text, a Japanese word with U+30FC or U+3005, a text with
// a tab or a CRLF line end, more than 2000 scalars in a context, a sentence full stop followed by a newline and more text,
// `wait…what`. Plain Portuguese, French, Russian or Chinese text without a dot, a label equal to its own address, and a
// link at the end of a sentence open.

/// The context reaches at most this many scalars on each side of the link text; a longer one asks.
private let maxContextSide = 300

/// A context of more than this many scalars (before normalising) asks, whatever it holds: the cost stays bounded.
private let maxContextScalars = 2000

private func isAnyLetter(_ s: Unicode.Scalar) -> Bool {
    switch s.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
    default: return false
    }
}

private func isLetterCategory(_ category: Unicode.GeneralCategory) -> Bool {
    switch category {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
    default: return false
    }
}

/// True when NFKC leaves the scalar as it is (a compatibility letter such as U+0140 changes).
private func unchangedByNFKC(_ s: Unicode.Scalar) -> Bool {
    let mapped = String(s).precomposedStringWithCompatibilityMapping.unicodeScalars
    return mapped.count == 1 && mapped.first == s
}

/// Rule 3: the Latin letters of U+00C0 to U+024F and U+1E00 to U+1EFF (the only place NFKC is asked).
private func isRule3Latin(_ value: UInt32) -> Bool {
    (value >= 0xC0 && value <= 0x24F) || (value >= 0x1E00 && value <= 0x1EFF)
}

/// Rule 4: the script groups whose letters are plain outside ASCII and rule 3, as bits: 1 Cyrillic, 2 Greek, 4 East Asian
/// (kana and Han share a group, as Japanese is written with both), 8 Hangul. 0: any other block, which asks.
/// The blocks are: Cyrillic U+0400 to U+04FF, Greek U+0370 to U+03FF, Hiragana and Katakana U+3040 to U+30FF, CJK unified
/// ideographs U+4E00 to U+9FFF, Hangul syllables U+AC00 to U+D7A3. They are the ones whose letters were measured in the
/// review scan at 13 pt: no letter in them is drawn as a dot or with no ink (smallest ink 2.5 pt wide and 6.9 pt tall in
/// Greek, 4.4 x 6.8 in Cyrillic, 5.0 x 5.3 in Han, 6.9 x 7.5 in kana, 10.3 x 9.4 in Hangul). Other blocks hold letters drawn
/// as a full stop, a dot or a comma (U+1BC94, U+1427, U+0D4E, U+071D...), so they ask; extend the list only with a block
/// whose scan is clean. The block ranges are tested without building a String; the category (Lu, Ll, Lt, Lo) is checked
/// by the caller.
private func scriptGroup(_ value: UInt32) -> UInt8 {
    if value < 0x0370 { return 0 }
    if value <= 0x03FF { return 2 }
    if value >= 0x0400 && value <= 0x04FF { return 1 }
    if (value >= 0x3040 && value <= 0x30FF) || (value >= 0x4E00 && value <= 0x9FFF) { return 4 }
    if value >= 0xAC00 && value <= 0xD7A3 { return 8 }
    return 0
}

/// Hangul fillers: letters that draw nothing.
private let invisibleLetters: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0]

/// Typographic marks that are plain text with a letter, an ASCII digit, an ASCII space or the edge of the context on each
/// side. None is a dot. The ellipsis is handled apart.
private let plainTypography: Set<UInt32> = [0x2019, 0x2018, 0x201C, 0x201D, 0x2014, 0x2013, 0xAB, 0xBB]

private func isASCIIDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }

/// An ASCII context delimiter: space, newline. Never a tab.
private func isContextDelimiter(_ s: Unicode.Scalar) -> Bool { s.value == 0x20 || s.value == 0x0A }

/// Closing ASCII punctuation that may follow a sentence's full stop.
private let closingPunctuation: Set<UInt32> = [0x29, 0x5D, 0x7D, 0x3E, 0x22, 0x27]

/// Punctuation stripped from both ends of a token before it is read as an address.
private let tokenPunctuation: Set<UInt8> = Set("()[]{}<>,;!?\"'".utf8)

/// The verdict on one context, independent of the destinations: it always asks, or it claims these hosts (www removed;
/// none: nothing in it names a host).
private struct ContextVerdict {
    let alwaysConfirm: Bool
    let claimed: Set<String>
    static let plain = ContextVerdict(alwaysConfirm: false, claimed: [])
    static let confirm = ContextVerdict(alwaysConfirm: true, claimed: [])
}

/// Judges a context (linear in its length, at most `maxContextScalars` of it). Called once per context.
/// `endsBeforeSpaceOrEnd`: after the context and any ASCII spaces comes the end of the block or a scalar that is not a newline.
private func judge(context scalars: [Unicode.Scalar], endsBeforeSpaceOrEnd: Bool) -> ContextVerdict {
    if scalars.isEmpty { return .plain }
    if scalars.count > maxContextScalars { return .confirm }
    let normalized: [Unicode.Scalar]
    if scalars.allSatisfy({ $0.isASCII }) {
        normalized = scalars
    } else {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        normalized = Array(String(view).precomposedStringWithCanonicalMapping.unicodeScalars)
    }
    let count = normalized.count

    // B. the words: a letter of an allowed script (rule 4) needs a word with letters of that one script group only, so
    // `wordMixed` marks every scalar of a word that holds an ASCII letter or digit, a rule 3 Latin letter, or two groups
    var wordMixed = [Bool](repeating: false, count: count)
    // a scalar of a word: a letter of any script or a decimal digit; the category is read once per scalar
    let categories = normalized.map { $0.properties.generalCategory }
    var start = 0
    while start < count {
        let first = categories[start]
        guard isLetterCategory(first) || first == .decimalNumber else { start += 1; continue }
        var end = start
        var foreign = false
        var groups: UInt8 = 0
        while end < count {
            let category = categories[end]
            guard isLetterCategory(category) || category == .decimalNumber else { break }
            let value = normalized[end].value
            if value < 0x80 || isRule3Latin(value) { foreign = true } else { groups |= scriptGroup(value) }
            end += 1
        }
        if foreign || groups & (groups &- 1) != 0 {
            var index = start
            while index < end { wordMixed[index] = true; index += 1 }
        }
        start = end
    }
    func neighbourIsFine(_ other: Unicode.Scalar?) -> Bool {
        guard let other else { return true }
        return isAnyLetter(other) || isASCIIDigit(other) || other == " "
    }
    for index in 0..<count {
        let scalar = normalized[index]
        if scalar.isASCII {
            if scalar.value < 0x20 || scalar.value > 0x7E { return .confirm }
            continue
        }
        let category = categories[index]
        let value = scalar.value
        // the common case first: a letter of an allowed block in a word of one group (no hashing, no neighbours)
        if scriptGroup(value) != 0, category != .modifierLetter, isLetterCategory(category) {
            if wordMixed[index] { return .confirm }
            continue
        }
        let previous: Unicode.Scalar? = index > 0 ? normalized[index - 1] : nil
        let next: Unicode.Scalar? = index + 1 < count ? normalized[index + 1] : nil
        if plainTypography.contains(value) {
            if neighbourIsFine(previous), neighbourIsFine(next) { continue }
            return .confirm
        }
        if value == 0x2026 {
            let spaceOrEdge = previous == nil || next == nil || previous == " " || next == " "
            if spaceOrEdge, neighbourIsFine(previous), neighbourIsFine(next) { continue }
            return .confirm
        }
        guard category != .modifierLetter, isLetterCategory(category), !invisibleLetters.contains(value) else { return .confirm }
        if isRule3Latin(value) {
            if unchangedByNFKC(scalar) { continue }
            return .confirm
        }
        if scriptGroup(value) == 0 || wordMixed[index] { return .confirm }
    }

    // D. the sentence full stop, C. punctuation between letters, the dotted contexts
    var sentenceDot = -1
    if endsBeforeSpaceOrEnd {
        var tail = count - 1
        while tail >= 0, closingPunctuation.contains(normalized[tail].value) { tail -= 1 }
        if tail >= 0, normalized[tail] == "." { sentenceDot = tail }
    }
    var dotted = false
    for index in 0..<count {
        let scalar = normalized[index]
        if scalar.value > 0x3B { continue }          // the marks below are all ASCII, U+002C to U+003B
        let next: Unicode.Scalar? = index + 1 < count ? normalized[index + 1] : nil
        switch scalar {
        case ".":
            if index != sentenceDot { dotted = true }
        case "/":
            if next == "/" { dotted = true }
        case ",", ";", ":":
            if scalar == ":", let next, isASCIIDigit(next) { dotted = true; continue }
            guard index > 0, let next else { continue }
            let previous = normalized[index - 1]
            guard isAnyLetter(previous) || isASCIIDigit(previous), isAnyLetter(next) || isASCIIDigit(next) else { continue }
            if scalar == ",", isASCIIDigit(previous), isASCIIDigit(next) { continue }
            return .confirm
        default:
            break
        }
    }
    guard dotted else { return .plain }
    guard let claimed = dottedTokenClaims(normalized, sentenceDot: sentenceDot) else { return .confirm }
    return ContextVerdict(alwaysConfirm: false, claimed: claimed)
}

/// What one dotted token says.
private enum TokenReading {
    case host(String)          // it names this host (www removed, lower case)
    case nothing               // a decimal or version number: no claim
    case notAnAddress          // anything else: the link asks
}

private func isHostByte(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F || b == 0x2E
}

/// Reads one token (ASCII bytes) that holds a dot, `//` or a colon before a digit: strips the punctuation at both ends and
/// one trailing full stop, then it is a decimal or version number, an address, or neither.
private func readToken(_ raw: ArraySlice<UInt8>) -> TokenReading {
    let dot = UInt8(ascii: "."), slash = UInt8(ascii: "/"), colon = UInt8(ascii: ":")
    var lo = raw.startIndex, hi = raw.endIndex
    while lo < hi, tokenPunctuation.contains(raw[lo]) { lo += 1 }
    var droppedDot = false
    while lo < hi {
        let last = raw[hi - 1]
        if tokenPunctuation.contains(last) { hi -= 1 }
        else if last == dot, !droppedDot { droppedDot = true; hi -= 1 }
        else { break }
    }
    let b = Array(raw[lo..<hi])
    guard !b.isEmpty else { return .notAnAddress }
    // a decimal or version number: digits and full stops after at most one sign or currency mark. It claims nothing, unless
    // it starts with four parts of 0 to 255: an IPv4 (a fifth part, as in `1.2.3.4.5`, does not hide it)
    let signed = b[0] == UInt8(ascii: "+") || b[0] == UInt8(ascii: "-") || b[0] == UInt8(ascii: "$")
    let number = b.dropFirst(signed ? 1 : 0)
    if number.contains(dot), number.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == dot }) {
        let parts = number.split(separator: dot, omittingEmptySubsequences: false)
        if !parts.contains(where: { $0.isEmpty }) {
            if parts.count >= 4, parts.prefix(4).allSatisfy({ $0.count <= 3 && Int(String(decoding: $0, as: UTF8.self))! <= 255 }) {
                return .host(parts.prefix(4).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "."))
            }
            return .nothing
        }
    }
    // an address: optional http or https scheme, host, optional port, then nothing or a path, query or fragment
    var i = 0
    let lowered = b.prefix(8).map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    if lowered.starts(with: Array("https://".utf8)) { i = 8 } else if lowered.starts(with: Array("http://".utf8)) { i = 7 }
    let hostStart = i
    while i < b.count, isHostByte(b[i]) { i += 1 }
    let host = b[hostStart..<i]
    guard !host.isEmpty, host.first != dot, host.last != dot, !host.split(separator: dot, omittingEmptySubsequences: false).contains(where: { $0.isEmpty })
    else { return .notAnAddress }
    if i < b.count, b[i] == colon {
        i += 1
        let portStart = i
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
        guard i > portStart else { return .notAnAddress }
    }
    if i < b.count, b[i] != slash, b[i] != UInt8(ascii: "?"), b[i] != UInt8(ascii: "#") { return .notAnAddress }
    return .host(withoutWWW(String(decoding: host, as: UTF8.self).lowercased()))
}

/// The hosts that the dotted tokens of a context name (www removed), or nil when one of them is not an address, so the
/// link asks. A token is a run of non space scalars; one that holds no dot, `//` or colon before a digit is plain words.
/// The sentence full stop is not a dot.
private func dottedTokenClaims(_ scalars: [Unicode.Scalar], sentenceDot: Int) -> Set<String>? {
    var claimed = Set<String>()
    let count = scalars.count
    var start = 0
    while start < count {
        if scalars[start] == " " { start += 1; continue }
        var end = start
        var holds = false
        var ascii = true
        var bytes: [UInt8] = []
        while end < count, scalars[end] != " " {
            let scalar = scalars[end]
            if scalar.isASCII { bytes.append(UInt8(scalar.value)) } else { ascii = false }
            if scalar == ".", end != sentenceDot { holds = true }
            else if scalar == "/", end + 1 < count, scalars[end + 1] == "/" { holds = true }
            else if scalar == ":", end + 1 < count, isASCIIDigit(scalars[end + 1]) { holds = true }
            end += 1
        }
        if holds {
            guard ascii else { return nil }
            switch readToken(bytes[...]) {
            case .host(let host): claimed.insert(host)
            case .nothing: break
            case .notAnAddress: return nil
            }
        }
        start = end
    }
    return claimed
}

/// The comparable host of a destination, nil when it must not open (fails `safeWebURL`, or a host that cannot be shown).
private func comparableHost(_ destination: String) -> String? {
    guard safeWebURL(destination) != nil, let host = linkDestinationHost(destination),
          host.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || ".-_:".unicodeScalars.contains($0)) })
    else { return nil }
    return withoutWWW(host)
}

/// What a verdict on a context does for destinations with these hosts: it asks, or nothing is claimed, or every host
/// claimed is every destination host.
private func decide(_ verdict: ContextVerdict, hosts: [Set<String>]) -> LinkClick {
    if verdict.alwaysConfirm { return .confirm }
    if verdict.claimed.isEmpty { return .open }
    guard verdict.claimed.count == 1, let claimed = verdict.claimed.first else { return .confirm }
    return hosts.allSatisfy({ $0.allSatisfy { $0 == claimed } }) ? .open : .confirm
}

/// A click on a link of an answer, from the context as drawn (the whole text around the link, see the rule above, no cap
/// here: `linkGroups` applies it) and the destination of each link run in it. `discard` when any destination fails
/// `safeWebURL` or has a host that cannot be shown; otherwise `open` or `confirm` by the rule.
func linkClick(label: String, destinations: [String]) -> LinkClick {
    guard !destinations.isEmpty else { return .discard }
    var hosts = Set<String>()
    for destination in destinations {
        guard let host = comparableHost(destination) else { return .discard }
        hosts.insert(host)
    }
    return decide(judge(context: Array(label.unicodeScalars), endsBeforeSpaceOrEnd: true), hosts: [hosts])
}

func linkClick(label: String, destination: String) -> LinkClick { linkClick(label: label, destinations: [destination]) }

// MARK: - A block of text with links, judged in context

/// One run of the text of a block: its text and the destination of its link, nil when it has none.
struct LinkRun: Equatable {
    let text: String
    let destination: String?
}

/// Adjacent link runs (one drawn link as far as the eye goes): the runs, their text (what the dialog shows), their
/// destinations and what a click does.
struct LinkGroup: Equatable {
    let runs: Range<Int>
    let label: String
    let destinations: [String]
    let outcome: LinkClick
}

/// A link is judged in its context (see the rule above): the text of the group extended on both sides to the nearest ASCII
/// space or newline in the whole block, through runs with or without a link (an invisible character, a dot or a
/// letter between two links or glued to one does not hide the address they draw together). The destinations compared are
/// those of every link run in that text; a neighbour whose destination can never open does not discard an honest link.
/// Linear in the length of the block: the delimiters are found in two passes, and a context is judged once and reused by
/// every group inside it.
func linkGroups(_ runs: [LinkRun]) -> [LinkGroup] {
    var scalars: [Unicode.Scalar] = []
    var owner: [Int] = []                       // run index of each scalar
    var runStart: [Int] = []                    // offset of each run's first scalar, one more for the end
    for (index, run) in runs.enumerated() {
        runStart.append(scalars.count)
        for scalar in run.text.unicodeScalars { scalars.append(scalar); owner.append(index) }
    }
    runStart.append(scalars.count)
    let total = scalars.count
    // previousDelimiter[i]: the last delimiter before i (-1: none); nextDelimiter[i]: the first delimiter at or after i (total: none)
    var previousDelimiter = [Int](repeating: -1, count: total + 1)
    var last = -1
    var i = 0
    while i < total { previousDelimiter[i] = last; if isContextDelimiter(scalars[i]) { last = i }; i += 1 }
    previousDelimiter[total] = last
    var nextDelimiter = [Int](repeating: total, count: total + 1)
    var next = total
    // nextNonSpace[i]: the first index at or after i that is not an ASCII space (total: none)
    var nextNonSpace = [Int](repeating: total, count: total + 1)
    var nonSpace = total
    i = total - 1
    while i >= 0 {
        if isContextDelimiter(scalars[i]) { next = i }
        nextDelimiter[i] = next
        if scalars[i] != " " { nonSpace = i }
        nextNonSpace[i] = nonSpace
        i -= 1
    }
    let hostOfRun: [String?] = runs.map { $0.destination.flatMap(comparableHost) }

    struct ContextKey: Hashable { let lo: Int; let hi: Int }
    var judged: [ContextKey: (verdict: ContextVerdict, hosts: Set<String>)] = [:]

    var groups: [LinkGroup] = []
    var index = 0
    while index < runs.count {
        guard runs[index].destination != nil else { index += 1; continue }
        var end = index
        var own: [String] = []
        var label = ""
        while end < runs.count, let destination = runs[end].destination {
            own.append(destination); label += runs[end].text; end += 1
        }
        let outcome: LinkClick
        if (index..<end).contains(where: { hostOfRun[$0] == nil }) {
            outcome = .discard
        } else {
            let first = runStart[index], after = runStart[end]
            let lo = previousDelimiter[first] + 1, hi = nextDelimiter[after]
            if first - lo > maxContextSide || hi - after > maxContextSide || hi - lo > maxContextScalars {
                outcome = .confirm
            } else {
                let key = ContextKey(lo: lo, hi: hi)
                let entry: (verdict: ContextVerdict, hosts: Set<String>)
                if let known = judged[key] {
                    entry = known
                } else {
                    var hosts = Set<String>()
                    if lo < hi { for runIndex in owner[lo]...owner[hi - 1] { if let host = hostOfRun[runIndex] { hosts.insert(host) } } }
                    let following = nextNonSpace[hi]
                    let endsBeforeSpaceOrEnd = following == total || scalars[following] != "\n"
                    entry = (judge(context: Array(scalars[lo..<hi]), endsBeforeSpaceOrEnd: endsBeforeSpaceOrEnd), hosts)
                    judged[key] = entry
                }
                // the own destinations count even for a group with no text of its own
                let ownHosts = Set((index..<end).compactMap { hostOfRun[$0] })
                outcome = decide(entry.verdict, hosts: [entry.hosts, ownHosts])
            }
        }
        groups.append(LinkGroup(runs: index..<end, label: label, destinations: own, outcome: outcome))
        index = end
    }
    return groups
}

/// R6: the destinations that may open at once: those whose every group opens. Anything else asks, so a lookup that
/// misses fails toward the dialog.
func linkDestinationsThatOpen(_ groups: [LinkGroup]) -> Set<String> {
    var opens = Set<String>()
    var blocked = Set<String>()
    for group in groups {
        for destination in group.destinations {
            if group.outcome == .open { opens.insert(destination) } else { blocked.insert(destination) }
        }
    }
    return opens.subtracting(blocked)
}

// MARK: - The confirmation dialog text

private let maxDialogLabel = 60
private let dialogQuotes: Set<UInt32> = [0x22, 0x27, 0x60, 0xAB, 0xBB, 0x2018, 0x2019, 0x201A, 0x201B, 0x201C, 0x201D, 0x201E, 0x201F,
                                         0x2039, 0x203A, 0x300C, 0x300D, 0x300E, 0x300F, 0xFF02, 0xFF07]

/// The two facts the confirmation shows: the host first and alone (ASCII, cut from the left at 40 whatever its shape),
/// then the label as a short plain line: no format characters, every whitespace or control character one space, the quote
/// characters the sentence uses stripped, at most 60 scalars.
func linkDialogParts(destination: String, label: String) -> (host: String, label: String) {
    var host = linkShownHost(destination) ?? linkDestinationHost(destination) ?? ""
    if host.count > maxShownHost { host = "\u{2026}" + host.suffix(maxShownHost) }
    var line = String.UnicodeScalarView()
    var pendingSpace = false
    for scalar in label.unicodeScalars {
        let category = scalar.properties.generalCategory
        if category == .format || dialogQuotes.contains(scalar.value) { continue }
        if scalar.properties.isWhitespace || category == .control || category == .lineSeparator || category == .paragraphSeparator || category == .spaceSeparator {
            pendingSpace = true; continue
        }
        if pendingSpace, !line.isEmpty { line.append(" ") }
        pendingSpace = false
        line.append(scalar)
    }
    let scalars = Array(line)
    var shown = String.UnicodeScalarView()
    shown.append(contentsOf: scalars.prefix(maxDialogLabel))
    return (host, String(shown) + (scalars.count > maxDialogLabel ? "\u{2026}" : ""))
}

/// The hover text of a block of text: the shown host of each link that can open, once each, in order of appearance.
/// Empty when there is none (the caller then sets no help at all).
func linkTooltip(destinations: [String]) -> String {
    var seen: [String] = []
    for destination in destinations {
        if let host = linkShownHost(destination), !seen.contains(host) { seen.append(host) }
    }
    return seen.joined(separator: "\n")
}

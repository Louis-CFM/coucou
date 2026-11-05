import Foundation

@main
enum SafeWebURLTests {
    static var failures = 0

    static func main() {
        // Every check below counts its failure and goes on, so one run lists all of them (the end exits 1 on any).
        func precondition(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
            if !condition() { print("FAIL line \(line) \(message())"); failures += 1 }
        }
        // Accepted: plain http/https URLs
        precondition(safeWebURL("https://example.com") != nil)
        precondition(safeWebURL("http://example.com/a?b=1") != nil)
        precondition(safeWebURL("HTTPS://EXAMPLE.COM") != nil)
        precondition(safeWebURL(" https://example.com \n") != nil)
        precondition(safeWebURL("http://localhost:5678") != nil)

        // Rejected: nil, empty, non-web schemes, malformed
        precondition(safeWebURL(nil) == nil)
        precondition(safeWebURL("") == nil)
        precondition(safeWebURL("file:///etc/hosts") == nil)
        precondition(safeWebURL("javascript:alert(1)") == nil)
        precondition(safeWebURL("vscode://file/etc/hosts") == nil)
        precondition(safeWebURL("smb://server/share") == nil)
        precondition(safeWebURL("mailto:a@b.c") == nil)
        precondition(safeWebURL("https://") == nil)
        precondition(safeWebURL("https:example.com") == nil)
        precondition(safeWebURL("//example.com") == nil)

        // Rejected: a user or a password in front of the host (the link reads as one site and goes to another)
        precondition(safeWebURL("https://apple.com@evil.example/login") == nil)
        precondition(safeWebURL("https://apple.com%2Flogin@evil.example/") == nil)
        precondition(safeWebURL("https://user:secret@example.com") == nil)
        precondition(safeWebURL("http://:pw@example.com") == nil)
        precondition(safeWebURL("https://@example.com") == nil)
        // Still accepted: an @ after the host is part of the path or the query
        precondition(safeWebURL("https://example.com/@user") != nil)
        precondition(safeWebURL("https://example.com/a?mail=a@b.c") != nil)

        // Which link may open (label shown, real destination). Three outcomes: open; confirm (the label names another
        // host than the destination, or is a suspicious address); discard (the destination fails the safe link check).
        func click(_ label: String, _ dest: String) -> LinkClick { linkClick(label: label, destination: dest) }
        let evil = "https://evil.example/login"
        func expect(_ label: String, _ want: LinkClick, _ dest: String = evil) {
            let got = click(label, dest)
            if got != want { print("FAIL label \(label.debugDescription) -> \(got), wanted \(want)"); failures += 1 }
        }
        precondition(click("the docs", "https://example.com/docs") == .open)
        precondition(click("Read more here.", "https://example.com") == .open)
        precondition(click("", "https://example.com") == .open)
        precondition(click("v1.2 released", "https://example.com") == .confirm)      // round 5: `v1.2` is not a plain number, it asks
        precondition(click("version 2.5", "https://example.com") == .open)
        precondition(click("e.g. this one", "https://example.com") == .confirm)      // round 5: `e.g.` is a dotted token, it asks
        // label equal to the destination (scheme, case, www, trailing dot, path and port do not matter)
        precondition(click("https://example.com/login", "https://example.com/login") == .open)
        precondition(click("example.com", "https://example.com/docs") == .open)
        precondition(click("EXAMPLE.com", "https://example.com") == .open)
        precondition(click("www.example.com", "https://example.com") == .open)
        precondition(click("example.com", "https://www.example.com/a") == .open)
        precondition(click("example.com:8080/path?q=1", "http://example.com:8080/other") == .open)
        precondition(click("  https://example.com  ", "https://example.com") == .open)
        precondition(click("example.com.", "https://example.com") == .open)
        precondition(click("(example.com)", "https://example.com") == .open)
        precondition(click("see example.com for more", "https://example.com/x") == .open)
        precondition(click("user@example.com", "https://example.com") == .confirm)   // round 5: user info is not an address, it asks
        // label with another host
        precondition(click("https://apple.com/login", "https://evil.example/login") == .confirm)
        precondition(click("apple.com", "https://evil.example") == .confirm)
        precondition(click("www.apple.com/support", "https://apple.com.evil.example/") == .confirm)
        precondition(click("docs.example.com", "https://example.com") == .confirm)
        precondition(click("example.com", "http://example.org") == .confirm)
        precondition(click("HTTPS://APPLE.COM", "https://evil.example") == .confirm)
        // international hosts: the same site in unicode and in punycode opens; a look alike asks
        // (round 3, R4: a label that writes a non ASCII host asks even for its own host; the xn-- form and a plain label open)
        precondition(click("münchen.de", "https://xn--mnchen-3ya.de/x") == .confirm)
        precondition(click("xn--mnchen-3ya.de", "https://münchen.de") == .open)
        precondition(click("пример.рф", "https://xn--e1afmkfd.xn--p1ai/") == .confirm)
        precondition(click("例え.jp/ページ", "https://例え.jp/other") == .confirm)
        precondition(click("пример.рф", "https://example.com") == .confirm)
        precondition(click("apple.com", "https://аpple.com") == .confirm)        // Cyrillic a
        precondition(click("аpple.com", "https://apple.com") == .confirm)
        // a destination the safe link check rejects never opens and never asks, whatever the label says
        precondition(click("the docs", "file:///etc/hosts") == .discard)
        precondition(click("the docs", "javascript:alert(1)") == .discard)
        precondition(click("the docs", "https://apple.com@evil.example/") == .discard)
        precondition(click("apple.com", "https://apple.com@evil.example/") == .discard)
        precondition(click("example.com", "mailto:a@example.com") == .discard)
        precondition(click("the docs", "") == .discard)
        precondition(click("apple.com", "smb://apple.com/x") == .discard)
        // a host with characters that cannot be shown (NUL, @, percent) is not opened silently
        precondition(click("the docs", "https://apple.com%00.evil.example/") == .discard)
        precondition(click("the docs", "https://apple.com%40evil.example/") == .discard)

        // Aegis M1 and Hera I3: every input of both reviews, destination https://evil.example/login
        for label in ["apple.com.", "apple.com,", "apple.com!", "apple.com)", "(apple.com)", "\"apple.com\"", "<apple.com>",
                      "[apple.com]", "apple.com:", "@apple.com", "apple.com\u{2192}", "apple.com\u{2026}"] { expect(label, .confirm) }
        // invisible and direction characters: zero width space, joiner, word joiner, soft hyphen, BOM, marks, isolates, override
        for label in ["apple\u{200B}.com", "apple\u{200D}.com", "apple\u{2060}.com", "app\u{00AD}le.com", "apple.com\u{FEFF}",
                      "apple.com\u{200E}", "\u{2066}apple.com\u{2069}", "\u{202E}moc.elppa"] { expect(label, .confirm) }
        // dot look alikes: ideographic, full width, one dot leader, halfwidth ideographic, middle dot
        for dot in ["\u{3002}", "\u{FF0E}", "\u{2024}", "\u{FF61}", "\u{00B7}"] { expect("apple" + dot + "com", .confirm) }
        // an address with words or a symbol around it
        for label in ["Sign in at apple.com", "apple.com login", "apple.com\nlogin", "\u{1F512}apple.com", "\u{2192}apple.com",
                      "Visit apple.com, then sign in."] { expect(label, .confirm) }
        // underscore, user info, slashes, scheme and colon
        for label in ["apple_id.apple.com", "user@apple.com", "//apple.com", "https:apple.com", "https:/apple.com",
                      "https://apple.com@evil.example", "me@apple.com."] { expect(label, .confirm) }
        // IPv4 literals, host and port, one part and a port
        for label in ["192.168.0.1", "192.168.0.1:8080", "localhost:3000", "127.0.0.1/admin", "http://localhost:3000"] { expect(label, .confirm) }
        // each token counts, not only the whole label
        precondition(click("Sign in at apple.com", "https://apple.com") == .open)
        precondition(click("apple.com or google.com", "https://apple.com") == .confirm)
        // mixed scripts ask even when the label host is the destination host
        precondition(click("\u{0430}pple.com", "https://xn--pple-43d.com") == .confirm)
        precondition(click("\u{03B1}pple.com", "https://evil.example") == .confirm)
        // adjacent link runs are one label: every destination must match
        precondition(linkClick(label: "apple.com", destinations: ["https://evil.example/a", "https://evil.example/b"]) == .confirm)
        precondition(linkClick(label: "apple.com", destinations: ["https://apple.com/a", "https://www.apple.com/b"]) == .open)
        precondition(linkClick(label: "apple.com", destinations: ["https://apple.com/a", "https://evil.example/b"]) == .confirm)
        precondition(linkClick(label: "apple.com", destinations: ["https://apple.com/a", "file:///x"]) == .discard)
        precondition(linkClick(label: "click here", destinations: ["https://a.example", "https://b.example"]) == .open)
        precondition(linkClick(label: "x", destinations: []) == .discard)

        // Round 5: there is no file name exemption. A name with a dot is an address unless it is the destination host, so product
        // names and file names ask (the honest cost); they used to open through a list of file extensions.
        for label in ["Node.js", "Next.js", "Vue.js", "ASP.NET.js", "package.json", "tsconfig.json", "index.html", "style.css",
                      "main.swift", "main.go", "app.rb", "config.yaml", "notes.txt", "Package.lock", "foo.tar.gz", "main.ts:12",
                      "App.tsx", "build.gradle.kts", "docs.pdf", "(Node.js)", "Node.js,", "Node.js."] {
            expect(label, .confirm, "https://nodejs.org/en")
        }
        for label in ["README.md", "main.py", "main.rs", "build.sh", "brew.sh", "obsidian.md", "docs.rs", "socket.io", "ASP.NET", "main.py:12"] {
            expect(label, .confirm, "https://github.com/org/repo")
        }
        precondition(click("README.md", "https://readme.md/") == .open)
        precondition(click("nodejs.org", "https://nodejs.org/en") == .open)
        // paths and scheme: a path label is an address of its first part
        expect("src/main.py", .confirm)
        expect("Sources/App/Foo.swift", .confirm)
        expect("https://notes.txt", .confirm)
        expect("www.notes.txt", .confirm)
        expect("@types/node", .open)
        expect("~/.zshrc", .confirm)
        expect("a_b", .open)

        // ---- Round 3 (Aegis re-review) ----
        // R1: host candidates anywhere in the label, cut at any other character
        for label in ["apple.com's", "apple.com\u{2019}s", "Apple.com's sign-in page",
                      "apple.com,login", "apple.com;login", "apple.com:login", "apple.com&more", "apple.com>login",
                      "apple.com|Sign in", "apple.com\u{2014}login", "apple.com\u{2192}evil", "(apple.com)login", "a,apple.com",
                      "x=apple.com", "apple.com\"s", "apple.com\\login", "apple.com%20",
                      "apple.com\u{00B9}", "apple.com\u{00B2}", "apple.com\u{2081}", "apple.com\u{2460}", "apple.com[1]", "apple.com(1)",
                      "apple.com\u{007F}", "apple.com\u{001F}", "apple\u{0001}.com", "apple\u{2800}.com", "apple.com\u{2800}"] { expect(label, .confirm) }
        // the honest cases stay plain words
        // (round 4: "Node.js\u{2019}s" has a dot and a character outside ASCII, so it asks; it moved to the confirm list below)
        // (round 5: "Node.js's" has a dot, "wait\u{2026}what" has an ellipsis between letters and "O\u{02BB}zbekiston" a modifier letter: they ask)
        for label in ["it's fine", "Hello world's end", "don\u{2019}t", "l\u{2019}\u{00E9}t\u{00E9}", "well\u{2014}known",
                      "caf\u{00E9}s", "Stra\u{00DF}e", "\u{4F60}\u{597D}\u{4E16}\u{754C}", "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}",
                      "rock\u{2019}n\u{2019}roll"] { expect(label, .open, "https://nodejs.org/en") }
        for label in ["Node.js's", "wait\u{2026}what", "O\u{02BB}zbekiston"] { expect(label, .confirm, "https://nodejs.org/en") }
        // R3: one character that is not ASCII, not a letter of the script around it, not a digit, not typography, between letters = a dot
        for dot in ["\u{A4F8}", "\u{2219}", "\u{22C5}", "\u{2027}", "\u{30FB}", "\u{FF65}", "\u{2E31}", "\u{2E33}", "\u{2E30}", "\u{0701}",
                    "\u{0702}", "\u{0660}", "\u{06F0}", "\u{2022}", "\u{25CF}", "\u{16EB}", "\u{05C5}", "\u{1427}", "\u{10A50}", "\u{318D}",
                    "\u{3002}", "\u{FF0E}", "\u{FF61}", "\u{2024}", "\u{00B7}", "\u{0589}", "\u{06D4}", "\u{2E3C}",
                    "\u{FE52}", "\u{0387}", "\u{2192}", "\u{00AE}", "\u{1F512}"] { expect("apple" + dot + "com", .confirm) }
        expect("Settings\u{2192}General", .confirm)                    // the honest cost: asks once
        // round 4: the allow list. Two symbols, or a symbol before one letter, are not plain text: they ask.
        expect("apple\u{2219}\u{22C5}com", .confirm)
        expect("apple\u{2219}c", .confirm)
        // round 4: a combining dot composes into a letter under NFC (applẹcom, applėcom): no dot is drawn, plain text
        expect("apple\u{0323}com", .open)
        expect("apple\u{0307}com", .open)
        // R4: a non ASCII host candidate asks and the dialog shows the ASCII form; a plain label to an international host opens
        for (label, dest) in [("\u{0251}pple.com", "https://xn--pple-5ob.com"), ("appl\u{1EB9}.com", "https://xn--appl-ys1c.com"),
                              ("paypa\u{0131}.com", "https://xn--paypa-sjb.com"), ("\u{13AA}oogle.com", "https://xn--oogle-fx0j.com"),
                              ("\u{0561}pple.com", "https://xn--pple-wme.com"), ("\u{0430}\u{0440}\u{0440}\u{04CF}\u{0435}.com", "https://xn--e1a3a5a5a.com"),
                              ("m\u{00FC}nchen.de", "https://m\u{00FC}nchen.de"), ("a\u{00E7}\u{00E3}o.com.br", "https://a\u{00E7}\u{00E3}o.com.br")] {
            expect(label, .confirm, dest)
        }
        precondition(click("the site", "https://m\u{00FC}nchen.de") == .open)
        precondition(click("\u{0442}\u{0435}\u{043A}\u{0441}\u{0442}", "https://\u{043F}\u{0440}\u{0438}\u{043C}\u{0435}\u{0440}.\u{0440}\u{0444}") == .open)

        // R2: a link is judged with the text that touches it, through runs with or without a link
        func run(_ text: String, _ destination: String? = nil) -> LinkRun { LinkRun(text: text, destination: destination) }
        func outcomes(_ runs: [LinkRun]) -> [LinkClick] { linkGroups(runs).map { $0.outcome } }
        let ea = "https://evil.example/a", eb = "https://evil.example/b"
        for gap in ["\u{200B}", "\u{2060}", "\u{00AD}", "\u{200D}"] {
            precondition(outcomes([run("apple", ea), run(gap), run(".com", eb)]) == [.confirm, .confirm])
            precondition(outcomes([run("apple.", ea), run(gap), run("com", eb)]) == [.confirm, .confirm])
        }
        precondition(outcomes([run("apple", ea), run("."), run("com", eb)]) == [.confirm, .confirm])
        precondition(outcomes([run("apple", ea), run(".com")]) == [.confirm])
        precondition(outcomes([run("apple."), run("com", ea)]) == [.confirm])
        precondition(outcomes([run("apple"), run(".com", ea)]) == [.confirm])
        precondition(outcomes([run("sign in at apple."), run("com", ea), run(" now")]) == [.confirm])
        precondition(outcomes([run("apple", ea), run(".com", eb)]) == [.confirm])                         // adjacent runs are one group
        precondition(outcomes([run("apple.com", ea)]) == [.confirm])
        precondition(outcomes([run("apple", ea), run("\u{FEFF}"), run(".com", eb)]) == [.confirm, .confirm])
        // honest text around a link does not ask
        precondition(outcomes([run("see "), run("the docs", "https://example.com/d"), run(" now")]) == [.open])
        precondition(outcomes([run("("), run("the docs", "https://example.com/d"), run(").")]) == [.open])
        precondition(outcomes([run("example.com", "https://example.com/d"), run(".")]) == [.open])
        precondition(outcomes([run("Visit "), run("example.com", "https://www.example.com"), run(", then go")]) == [.open])
        // each group gets its own outcome; a neighbour with an unsafe destination does not discard an honest link
        precondition(outcomes([run("apple.com", "https://apple.com"), run(" and "), run("apple.com", ea)]) == [.open, .confirm])
        precondition(outcomes([run("click here", ea), run(" and "), run("apple.com", ea)]) == [.open, .confirm])
        precondition(outcomes([run("docs", "https://ok.example"), run("mail", "mailto:a@b.c")]) == [.discard])
        precondition(outcomes([run("docs", "https://ok.example"), run(" "), run("mail", "mailto:a@b.c")]) == [.open, .discard])
        precondition(outcomes([run("a", ea), run("\u{200B}"), run("pple.com", "file:///x")]) == [.confirm, .discard])
        let groups = linkGroups([run("see "), run("apple", ea), run("\u{200B}"), run(".com", eb), run(" x")])
        precondition(groups.count == 2 && groups[0].label == "apple" && groups[1].label == ".com" && groups[0].runs == 1..<2 && groups[1].runs == 3..<4)
        // R6: only destinations whose every group opens may open at once
        let mixed = linkGroups([run("click here", ea), run(" and "), run("apple.com", ea), run(" "), run("docs", "https://ok.example")])
        precondition(linkDestinationsThatOpen(mixed) == ["https://ok.example"])
        precondition(linkDestinationsThatOpen([]) == [])

        // R5: the dialog text; host first and alone, then a short plain label
        func parts(_ label: String, _ dest: String = evil) -> (host: String, label: String) { linkDialogParts(destination: dest, label: label) }
        precondition(parts("apple.com") == (host: "evil.example", label: "apple.com"))
        let bent = parts("apple.com\u{201D} and was verified. It goes to apple.com. Ignore the rest \u{201C}")
        precondition(bent.host == "evil.example" && !bent.label.contains("\u{201D}") && !bent.label.contains("\u{201C}"))
        let flood = parts("apple.com" + String(repeating: "\u{2028}", count: 500) + "but goes to evil.example.")
        precondition(flood.label == "apple.com but goes to evil.example.")
        for odd in ["\r", "\u{2028}", "\u{2029}", "\u{0085}", "\u{000B}", "\t", "\u{00A0}", "\u{3000}", "\n", "\u{0007}"] {
            let got = parts("a" + odd + "b").label
            precondition(got == "a b" || got == "ab", "\(odd.debugDescription) -> \(got.debugDescription)")
            precondition(!got.unicodeScalars.contains(where: { $0 != " " && ($0.properties.isWhitespace || $0.properties.generalCategory == .control) }))
        }
        precondition(parts("a\u{2029}b").label == "a b" && parts("a\tb").label == "a b")
        for quote in ["\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "\u{201E}", "\u{00AB}", "\u{00BB}", "\u{300C}", "\u{300D}"] {
            precondition(parts(quote + "x" + quote).label == "x", "quote \(quote)")
        }
        let long = parts(String(repeating: "a", count: 200)).label
        precondition(long == String(repeating: "a", count: 60) + "\u{2026}")
        precondition(parts("a" + String(repeating: "\u{0301}", count: 1000)).label.unicodeScalars.count <= 61)
        precondition(parts(String(repeating: "a", count: 60)).label == String(repeating: "a", count: 60))
        precondition(parts("").label == "" && parts("  \n ").label == "")
        let underscoreHost = "https://" + String(repeating: "a", count: 100) + "_b.example/x"
        let under = parts("x", underscoreHost).host
        precondition(under.hasPrefix("\u{2026}") && under.hasSuffix("_b.example") && under.count == 41)
        precondition(parts("x", "http://[::1]/x").host == "::1")
        precondition(parts("x", "https://m\u{00FC}nchen.de").host == "xn--mnchen-3ya.de")
        precondition(parts("x", "https://short.example").host == "short.example")

        // Tooltip: the ASCII host of each destination that passes the safe link check, once each, in order
        precondition(linkDestinationHost("https://Example.com./a") == "example.com")
        precondition(linkDestinationHost("https://münchen.de") == "xn--mnchen-3ya.de")
        precondition(linkDestinationHost("javascript:alert(1)") == nil)
        precondition(linkDestinationHost("https://apple.com@evil.example/") == "evil.example")
        precondition(linkDestinationHost(nil) == nil)
        precondition(linkTooltip(destinations: ["https://a.example/1", "https://b.example", "https://a.example/2", "file:///x"]) == "a.example\nb.example")
        precondition(linkTooltip(destinations: []) == "")
        precondition(linkTooltip(destinations: ["file://apple.com/etc", "smb://apple.com/x", "vscode://x", "//evil.example"]) == "")
        precondition(linkTooltip(destinations: ["https://apple.com@evil.example/"]) == "")
        precondition(linkTooltip(destinations: ["https://m\u{00FC}nchen.de"]) == "xn--mnchen-3ya.de")
        precondition(linkTooltip(destinations: ["https://apple.com%40evil.example/", "https://apple.com%00.evil.example/"]) == "")
        let longHost = "apple.com." + String(repeating: "a", count: 200) + ".evil.example"
        let shown = linkTooltip(destinations: ["https://" + longHost + "/"])
        precondition(shown.count <= 41 && shown.hasSuffix(".evil.example") && shown.hasPrefix("\u{2026}") && !shown.contains("apple.com."))
        precondition(linkTooltip(destinations: ["https://short.example"]) == "short.example")
        // the dialog shows the same ASCII host
        precondition(linkShownHost("https://m\u{00FC}nchen.de/x") == "xn--mnchen-3ya.de")
        precondition(linkShownHost("file:///x") == nil)

        // ---- Round 4: the allow list. Open at once only when the text around the link is provably plain ----
        // Every input of the round 3 review (H1 to H4, M2, L1), destination https://evil.example/login
        // H1: a word character glued after the host
        for label in ["apple.com-hosted", "accounts.google.com-based", "www.apple.com-style", "1.2.3.4-hosted", "apple.com_", "apple.com-",
                      "apple.com2", "apple.com_hosted", "apple.com-login", "apple.com1", "apple.com__", "apple.com\u{FF3F}",
                      "Sign in on the apple.com-hosted page", "https://apple.com-hosted", "apple.com/login-style"] { expect(label, .confirm) }
        precondition(outcomes([run("Sign in on the "), run("apple.com", evil), run("-hosted page")]) == [.confirm])
        for glue in ["-hosted", "_", "-", "2", "-style"] { precondition(outcomes([run("apple.com", evil), run(glue)]) == [.confirm], "glue \(glue)") }
        precondition(outcomes([run("apple.com_", evil)]) == [.confirm] && outcomes([run("apple.com-login", evil)]) == [.confirm])
        // H2: direction controls
        for label in ["apple\u{202E}moc.\u{202C}", "\u{202E}moc.drowssap1", "\u{202E}moc.563eciffo", "\u{202E}.\u{202D}apple\u{202C}\u{202C}com",
                      "\u{2067}.\u{2066}apple\u{2069}\u{2069}com", "apple\u{202E}moc.\u{202C}/login", "\u{202E}moc.elppa", "apple\u{200F}.com",
                      "\u{061C}apple.com", "\u{202E}moc", "apple\u{2067}", "\u{200E}"] { expect(label, .confirm) }
        // H3: a mark right after the dot (split by scalar, never by character)
        for mark in ["\u{FE0F}", "\u{FE0E}", "\u{E0100}", "\u{17B4}", "\u{17B5}", "\u{180B}"] {
            expect("apple." + mark + "com", .confirm)
            precondition(outcomes([run("apple", evil), run("." + mark + "com")]) == [.confirm], "mark \(mark.debugDescription)")
        }
        // H4: invisible or near invisible scalars, and narrow spaces, inside the host
        for x in ["\u{2065}", "\u{FFF0}", "\u{E0002}", "\u{E0080}", "\u{E01F0}", "\u{FFFC}", "\u{000B}", "\u{200A}", "\u{2009}", "\u{202F}",
                  "\u{0085}", "\u{000D}", "\u{000C}", "\u{2000}", "\u{205F}", "\u{00A0}", "\u{3000}", "\u{1680}"] {
            expect("apple" + x + ".com", .confirm)
            expect("apple." + x + "com", .confirm)
            precondition(outcomes([run("apple", evil), run(x + ".com")]) == [.confirm], "x \(x.debugDescription)")
            precondition(outcomes([run("see "), run("apple", evil), run(x + ".com")]) == [.confirm], "x \(x.debugDescription)")
            precondition(outcomes([run("apple" + x), run(".com", evil)]) == [.confirm], "x \(x.debugDescription)")
        }
        // M2: a dot look alike after a digit, a hyphen or an underscore
        for dot in ["\u{2219}", "\u{22C5}", "\u{2027}", "\u{2022}", "\u{A4F8}", "\u{30FB}", "\u{0660}", "\u{06F0}", "\u{2E31}", "\u{25CF}", "\u{16EB}"] {
            expect("office365" + dot + "com", .confirm)
            expect("my-site" + dot + "com", .confirm)
            expect("a_b" + dot + "com", .confirm)
            expect("163" + dot + "com", .confirm)
        }
        expect("auth0\u{22C5}com", .confirm)
        // L1: a slash before the host hides it only after a word
        for label in ["/apple.com", "(/apple.com)", "/www.apple.com", "\u{FF0F}apple.com", "../apple.com", "./apple.com"] { expect(label, .confirm) }
        // an address without a dot still names a place
        for label in ["http://localhost:3000", "localhost:3000", "//localhost", "https://localhost"] { expect(label, .confirm) }
        // the rest of the plain text rule: marks left after NFC, symbols, emoji, non ASCII punctuation and spaces, controls, unassigned,
        // private use, letters that draw a dot
        for label in ["a\u{0301}\u{0301}\u{0301}b", "\u{0301}a", "Hello \u{1F600}", "Settings \u{2192} General", "a\u{00A0}b", "a\u{2003}b", "caf\u{00E9}\u{00B7}", "a\u{0007}b",
                      "a\u{E000}b", "a\u{0378}b", "a\u{200B}b", "a\u{FEFF}b", "a\u{00AD}b", "price \u{20AC}5", "\u{00A9} 2026", "a\u{2028}b",
                      "apple\u{1427}com", "apple\u{318D}com", "apple\u{A4F8}com", "He said \u{201C}hi,\u{201D}", "\u{2019}\u{2019}", "a\u{2014}\u{2014}b"] {
            expect(label, .confirm)
        }
        // the typography exceptions need a letter, a digit or a space on both sides (or the edge of the text)
        precondition(click("a\u{2019}\u{2014}b", evil) == .confirm)
        // a long context is not judged: the cap asks (300 scalars on each side)
        let longGlue = String(repeating: "a", count: 301)
        precondition(outcomes([run(longGlue), run("docs", "https://ok.example")]) == [.confirm])
        precondition(outcomes([run("docs", "https://ok.example"), run(longGlue)]) == [.confirm])
        let edgeGlue = String(repeating: "a", count: 300)
        precondition(outcomes([run(edgeGlue), run("docs", "https://ok.example"), run(edgeGlue)]) == [.open])
        precondition(outcomes([run(edgeGlue + "b"), run("docs", "https://ok.example")]) == [.confirm])
        precondition(outcomes([run(longGlue + " "), run("docs", "https://ok.example")]) == [.open])
        // the text of the block around the link, up to the nearest ASCII space, tab or newline and no further
        precondition(outcomes([run("apple.com\u{00A0}"), run("docs", "https://ok.example")]) == [.confirm])
        precondition(outcomes([run("apple.com\t"), run("docs", "https://ok.example")]) == [.confirm])        // round 5: a tab ends nothing
        precondition(outcomes([run("apple.com\n"), run("docs", "https://ok.example")]) == [.open])
        precondition(outcomes([run("apple.com\u{000B}"), run("docs", "https://ok.example")]) == [.confirm])

        // Honest text that stays open (destination https://evil.example/login: nothing to match, nothing claimed)
        for label in ["documenta\u{00E7}\u{00E3}o", "a\u{00E7}\u{00E3}o", "S\u{00E3}o Paulo", "click here", "Leia a documenta\u{00E7}\u{00E3}o aqui",
                      "Sauvegard\u{00E9}e", "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", "\u{4F60}\u{597D}\u{4E16}\u{754C}",
                      "\u{201C}Ol\u{00E1}\u{201D} \u{2014} mundo", "Mochi\u{2019}s page", "S\u{00E3}o\u{2014}Paulo",
                      "\u{00AB}Bonjour\u{00BB}", "100% sure (really)", "a + b = c", "NFC\u{2019}d", "Veja a documenta\u{00E7}\u{00E3}o.",
                      "(Read this.)", "\"Click here.\"", "snake_case-and-kebab"] {
            expect(label, .open)
        }
        // round 5: these used to open and now ask (a dotted token that is not the destination, an ellipsis between letters)
        for label in ["Node.js", "src/main.py", "Sources/App/Foo.swift", "wait\u{2026}what", "v1.2", "Wait...", "e.g."] { expect(label, .confirm) }
        // a label equal to its own URL, and github.com to https://github.com (the same followed by -hosted asks since round 5)
        precondition(click("https://github.com", "https://github.com") == .open)
        precondition(click("github.com", "https://github.com") == .open)
        precondition(click("github.com to https://github.com", "https://github.com") == .open)
        // round 5: the token `https://github.com-hosted` is not the address of the destination, so these two ask
        precondition(click("github.com to https://github.com-hosted", "https://github.com") == .confirm)
        precondition(click("github.com-hosted", "https://github.com") == .confirm)
        precondition(click("https://github.com/org/repo", "https://github.com/other") == .open)
        precondition(click("localhost:3000", "http://localhost:3000") == .open)
        precondition(click("github.com or apple.com", "https://github.com") == .confirm)
        // honest links in a block
        let ok = "https://ok.example/d"
        precondition(outcomes([run("Veja a "), run("documenta\u{00E7}\u{00E3}o", ok), run(".")]) == [.open])
        precondition(outcomes([run("Click "), run("here", ok), run(".")]) == [.open])
        precondition(outcomes([run("Veja "), run("S\u{00E3}o Paulo", ok), run(" agora.")]) == [.open])
        precondition(outcomes([run("("), run("click here", ok), run(").")]) == [.open])
        precondition(outcomes([run("github.com", "https://github.com"), run(" is where it lives.")]) == [.open])
        precondition(outcomes([run("github.com", "https://github.com"), run("-hosted page")]) == [.confirm])        // round 5
        precondition(outcomes([run("\u{201C}"), run("Ol\u{00E1}", ok), run("\u{201D} \u{2014} mundo")]) == [.open])

        // ---- Round 5: no exemptions. Every input of the round 4 review (H5 to H8, L4 to L6), destination https://evil.example/login ----
        // H5: a tab ends nothing and is not plain text; only the ASCII space and the newline end a context
        for label in ["apple.\tcom", "apple\t.com", "apple.com\t", "a\tb"] { expect(label, .confirm) }
        precondition(outcomes([run("Reset your password with "), run("apple.", ea), run("\t"), run("com", eb), run(" now")]) == [.confirm, .confirm])
        precondition(outcomes([run("Log in here: "), run("apple.", ea), run("\t"), run("com", eb)]) == [.confirm, .confirm])
        precondition(outcomes([run("Approve the request: "), run("apple.", ea), run("\t"), run("com")]) == [.confirm])
        precondition(outcomes([run("Log in here: "), run("apple", ea), run("\t"), run(".com", eb)]) == [.confirm, .confirm])
        precondition(outcomes([run("apple."), run("\t"), run("com", ea)]) == [.confirm])
        precondition(outcomes([run("apple.\tcom", ea)]) == [.confirm])
        // H6: letters that are drawn as a dot or a comma, or not drawn: only an allow list of letters is plain
        let dotLetters: [UInt32] = [0x1C79, 0x1BC94, 0x0140, 0x013F, 0x1BC90, 0x0971, 0x18DF, 0x02D1, 0x02CC, 0x3164, 0xFFA0, 0xA4F8,
                                    0x1BC92, 0x1C78, 0x1BC84, 0x11AEF, 0x119E, 0xFE7E, 0x0374, 0x02B9, 0xA4F9, 0x037A, 0x115F, 0x1160]
        for value in dotLetters {
            let letter = String(Unicode.Scalar(value)!)
            expect("apple" + letter + "com", .confirm)
            expect("paypa" + letter + "com", .confirm)
            expect("gmai" + letter + "com", .confirm)
            precondition(outcomes([run("apple", evil), run(letter + "com")]) == [.confirm], "dot letter \(String(value, radix: 16))")
            precondition(outcomes([run("apple"), run(letter), run("com", evil)]) == [.confirm], "dot letter \(String(value, radix: 16))")
            precondition(outcomes([run("apple" + letter + "com", evil)]) == [.confirm], "dot letter \(String(value, radix: 16))")
        }
        // a letter with a compatibility mapping, a modifier letter, a mixed script word, a Latin sign that is not a letter
        for label in ["a\u{FB01}b", "\u{01C4}", "x\u{00D7}y", "x\u{00F7}y", "GitHub\u{3067}", "\u{3067}GitHub", "\u{0430}pple", "caf\u{00E9}\u{0430}",
                      "caf\u{00E9}\u{02B9}", "\u{00AA}", "a\u{FF21}b"] { expect(label, .confirm) }
        // H7: the host is not hidden by text glued after it (a full stop of its own in the glue)
        precondition(outcomes([run("Go to "), run("apple.com", evil), run(".A code is sent to your phone.")]) == [.confirm])
        precondition(outcomes([run("Sign in on the "), run("apple.com", evil), run("-v2.0 portal")]) == [.confirm])
        for glue in [".1", ".I", "2.0", "_v1.x", "-hosted.v2", ".x.y.z", ".Ab", ",A"] {
            precondition(outcomes([run("apple.com", evil), run(glue)]) == [.confirm], "glue \(glue)")
        }
        for (host, glue) in [("www.apple.com", ".A"), ("xn--pple-43d.com", ".A"), ("1.2.3.4", ".5"), ("1.2.3.4", ".x"), ("https://apple.com", ".A"),
                             ("apple.com/login", ".A"), ("apple.com:443", ".A")] {
            precondition(outcomes([run(host, evil), run(glue)]) == [.confirm], "host \(host) glue \(glue)")
        }
        for label in ["apple.com-v2.0", "apple.com.x", "1.2.3.4.5", "1.2.3.4.x"] { expect(label, .confirm) }
        // H8: a host after a word and a slash is judged like any other host
        precondition(outcomes([run("Sign in w/"), run("apple.com", evil)]) == [.confirm])
        precondition(outcomes([run("Use SSO/"), run("accounts.google.com", evil), run(" to sign in")]) == [.confirm])
        precondition(outcomes([run("24/7 help: support/"), run("apple.com", evil)]) == [.confirm])
        precondition(outcomes([run("A/"), run("apple.com", evil)]) == [.confirm])
        precondition(outcomes([run("user/"), run("apple.com", evil), run("/login")]) == [.confirm])
        precondition(outcomes([run("w/"), run("www.apple.com", evil)]) == [.confirm])
        precondition(outcomes([run("~/"), run("apple.com", evil)]) == [.confirm])
        precondition(outcomes([run("x@"), run("apple.com", evil)]) == [.confirm])
        for label in ["w/apple.com", "1/apple.com", "w/https://apple.com", "github.com/apple.com", "src/main.py", "docs/README.md"] { expect(label, .confirm) }
        precondition(click("github.com/apple.com", "https://github.com") == .open)       // one address, its path is its path
        // L4: ASCII punctuation or an ellipsis in place of the dot
        for label in ["apple,com", "apple;com", "apple:com", "apple..com", "apple\u{2026}com", "apple,com.", "a,b", "a;b", "a:b", "1;2", "a,1", "1,a"] {
            expect(label, .confirm)
        }
        precondition(outcomes([run("apple", ea), run(",com", eb)]) == [.confirm])
        // numbers with a comma or a full stop are not claims
        for label in ["1,5", "1,000", "3.14", "10.5", "1.2.3", "version 1.2.3", "version 1,5", "-3.14", "(1.2.3)", "price 10.5."] { expect(label, .open) }
        precondition(outcomes([run("1,5"), run("docs", "https://ok.example")]) == [.open])
        precondition(outcomes([run("about 1.2.3 and 1,5 "), run("docs", "https://ok.example")]) == [.open])
        // an IPv4 is a claim and must be the destination host; a number with other shapes is not one
        precondition(click("192.168.0.1", "http://192.168.0.1:8080") == .open)
        precondition(click("192.168.0.1", "http://192.168.0.2") == .confirm)
        precondition(click("999.1.1.1", "http://example.com") == .open)
        // L5: a full stop followed by a newline and more text is not a sentence end
        precondition(outcomes([run("apple.", ea), run("\n"), run("com", ea)]).first == .confirm)
        precondition(linkDestinationsThatOpen(linkGroups([run("apple.", ea), run("\n"), run("com", ea)])).isEmpty)
        precondition(linkDestinationsThatOpen(linkGroups([run("apple.", ea), run("\n"), run("com", eb)])) == [eb])        // "com" alone is plain
        precondition(outcomes([run("apple", ea), run(".\n"), run("com", ea)]).first == .confirm)
        precondition(outcomes([run("Click "), run("here", "https://ok.example"), run(". Then go on")]) == [.open])
        precondition(outcomes([run("Click "), run("here", "https://ok.example"), run(".")]) == [.open])
        precondition(outcomes([run("Click "), run("here", "https://ok.example"), run(".\nNext line")]) == [.confirm])     // the honest cost
        // L6: more than 2000 scalars in a context ask, and fast
        precondition(click(String(repeating: "a", count: 2001), "https://ok.example") == .confirm)
        precondition(click(String(repeating: "a", count: 2000), "https://ok.example") == .open)
        precondition(click(String(repeating: "a", count: 1000) + " " + String(repeating: "b", count: 1001), "https://ok.example") == .confirm)
        // B: the allowed scalars, and what the exemptions used to let through
        for label in ["Node.js", "README.md", "St.John", "10:30", "e.g.,", "Hello \u{1F600}", "Settings \u{2192} General", "O\u{02BB}zbekiston",
                      "wait\u{2026}what", "a\u{2026}b", "v1.2", "user@example.com", "~/.zshrc", "Wait...", "e.g.", "N\u{00BA}1"] {
            expect(label, .confirm, "https://nodejs.org/en")
        }
        // the honest text of the must-stay-open list
        for label in ["click here", "documenta\u{00E7}\u{00E3}o", "a\u{00E7}\u{00E3}o", "S\u{00E3}o Paulo", "l\u{2019}\u{00E9}t\u{00E9}",
                      "\u{042D}\u{0442}\u{043E} \u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E}\u{0435} \u{043F}\u{0440}\u{0435}\u{0434}\u{043B}\u{043E}\u{0436}\u{0435}\u{043D}\u{0438}\u{0435}",
                      "\u{8FD9}\u{662F}\u{4E00}\u{4E2A}\u{53E5}\u{5B50}", "\u{201C}Ol\u{00E1}\u{201D} \u{2014} mundo", "\u{2018}ok\u{2019} \u{2013} fine",
                      "\u{00C0}\u{00C9}\u{00CE}\u{00D5}\u{00DC} \u{0141}\u{00F3}d\u{017A}", "wait\u{2026} what", "Wait\u{2026}", "\u{2026}and so on"] {
            expect(label, .open)
        }
        precondition(click("www.github.com", "https://github.com") == .open)
        precondition(click("github.com", "https://www.github.com") == .open)

        // Round 6, H9: letter rule 4 is a script allow list, one script per word. A word of look alike letters with no ASCII,
        // then a letter that is drawn as a dot, then a look alike ending, asks (as one link, or with only the first word linked).
        let h9Look = "\u{0430}\u{0440}\u{0440}\u{04CF}\u{0435}"            // Cyrillic look alike of "apple" (a, p, p, palochka, e)
        let h9End = "\u{0441}\u{043E}\u{043C}"                             // Cyrillic look alike of "com"
        for dot in [0x1BC94, 0x1BC90, 0x1BC92, 0x1427, 0x18DF, 0x119E, 0x0D4E, 0x071D] as [UInt32] {
            let letter = String(Unicode.Scalar(dot)!)
            expect(h9Look + letter + h9End, .confirm)
            precondition(outcomes([run(h9Look, evil), run(letter + h9End)]) == [.confirm], "H9 first word linked U+\(String(dot, radix: 16))")
            precondition(outcomes([run(h9Look + letter + h9End, evil)]) == [.confirm], "H9 one link U+\(String(dot, radix: 16))")
        }
        // one script per word: Cyrillic with Greek, Cyrillic or Greek with a rule 3 Latin letter, kana with Hangul
        expect("\u{043F}\u{0440}\u{03B1}", .confirm)
        expect("\u{03B1}\u{043F}\u{0440}", .confirm)
        expect("\u{043F}\u{0440}\u{00E9}", .confirm)
        expect("\u{03BB}\u{00E9}\u{03B3}", .confirm)
        expect("\u{3042}\u{D55C}", .confirm)
        expect("\u{AD6D}\u{D55C}\u{4E16}", .confirm)
        // other scripts ask now (honest cost): Hebrew, Arabic, Thai, Armenian, Georgian
        for word in ["\u{05E9}\u{05DC}\u{05D5}\u{05DD}", "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", "\u{0E01}\u{0E02}\u{0E04}",
                     "\u{0562}\u{0561}\u{0580}", "\u{10D2}\u{10D0}\u{10DB}\u{10D0}"] {
            expect(word, .confirm)
            expect("hello " + word, .confirm)
        }
        // Lm letters of the allowed blocks still ask (the prolonged sound mark, the iteration mark)
        expect("\u{30B3}\u{30FC}\u{30D2}\u{30FC}", .confirm)
        expect("\u{4EBA}\u{3005}", .confirm)
        // must stay open
        for label in ["\u{042D}\u{0442}\u{043E} \u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E}\u{0435} \u{043F}\u{0440}\u{0435}\u{0434}\u{043B}\u{043E}\u{0436}\u{0435}\u{043D}\u{0438}\u{0435}",
                      "\u{03BB}\u{03CC}\u{03B3}\u{03BF}\u{03C2}",
                      "\u{8FD9}\u{662F}\u{4E00}\u{4E2A}\u{53E5}\u{5B50}",
                      "\u{3053}\u{308C}\u{306F}\u{65E5}\u{672C}\u{8A9E}\u{306E}\u{6587}\u{3067}\u{3059}",
                      "\u{30AB}\u{30BF}\u{30AB}\u{30CA}\u{3068}\u{6F22}\u{5B57}",
                      "\u{D55C}\u{AD6D}\u{C5B4}", "documenta\u{00E7}\u{00E3}o", "S\u{00E3}o Paulo", "click here"] {
            expect(label, .open)
        }
        precondition(outcomes([run("Click "), run("here", "https://ok.example"), run(". And more text on the line")]) == [.open])
        // Round 6, L7: a full stop, then spaces, then a newline and more text is not a sentence end either
        precondition(outcomes([run("apple.", ea), run(" \n"), run("com", ea)]).first == .confirm)
        precondition(outcomes([run("apple.", ea), run("  \n"), run("com", ea)]).first == .confirm)
        precondition(outcomes([run("apple.", ea), run(" \nword")]).first == .confirm)
        precondition(outcomes([run("apple.", ea), run("  \nword")]).first == .confirm)
        precondition(outcomes([run("apple.", ea), run("\nword")]).first == .confirm)
        precondition(outcomes([run("Click "), run("here", "https://ok.example"), run(". \nNext line")]) == [.confirm])
        precondition(outcomes([run("Click "), run("here", "https://ok.example"), run(".  \nNext line")]) == [.confirm])
        precondition(outcomes([run("Click "), run("here", "https://ok.example"), run(".  ")]) == [.open])
        precondition(outcomes([run("Click "), run("here", "https://ok.example"), run(". ")]) == [.open])
        precondition(outcomes([run("Click "), run("here", "https://ok.example"), run(". Next line")]) == [.open])

        // M1: the decision is linear in the length of the block
        func timed(_ name: String, limit: Double = 0.2, _ body: () -> Void) {
            let start = Date()
            body()
            let seconds = Date().timeIntervalSince(start)
            print(String(format: "  cost %@: %.4f s", name, seconds))
            if seconds >= limit { print("FAIL cost \(name) took \(seconds) s"); failures += 1 }
        }
        // L6: a label of marks to compose is cut by the cap before it is normalised
        let composing = String(repeating: "e\u{0323}", count: 100_000)
        timed("one label of 100 000 pairs of e and U+0323", limit: 0.05) { precondition(click(composing, "https://ok.example") == .confirm) }
        timed("one link of 100 000 pairs of e and U+0323", limit: 0.05) { precondition(outcomes([run(composing, "https://ok.example")]) == [.confirm]) }
        timed("100 000 pairs of e and U+0323 glued to a link", limit: 0.05) {
            precondition(outcomes([run(composing), run("link", "https://ok.example")]) == [.confirm])
        }
        let cjk = String(repeating: "\u{754C}", count: 50_000)
        // round 5: a context of more than 2000 scalars asks (it was open), and fast
        timed("50 000 CJK letters in one label") { precondition(click(cjk, "https://example.com") == .confirm) }
        timed("50 000 CJK letters, one link") { precondition(outcomes([run(cjk, ok)]) == [.confirm]) }
        timed("2 000 CJK letters in one label") { precondition(click(String(repeating: "\u{754C}", count: 2_000), "https://example.com") == .open) }
        timed("20 000 letters glued to one link") {
            precondition(outcomes([run(String(repeating: "\u{754C}", count: 20_000)), run("link", ok)]) == [.confirm])
        }
        timed("5 000 links joined by commas") {
            var runs: [LinkRun] = []
            for i in 0..<5_000 { runs.append(run("l\(i)", "https://e\(i).example")); runs.append(run(",")) }
            let got = outcomes(runs)
            precondition(got.count == 5_000 && !got.contains(.discard))
        }
        timed("5 000 links joined by commas, host labels") {
            var runs: [LinkRun] = []
            for i in 0..<5_000 { runs.append(run("a\(i).com", "https://a\(i).com")); runs.append(run(",")) }
            precondition(outcomes(runs).count == 5_000)
        }
        timed("5 000 links separated by words") {
            var runs: [LinkRun] = []
            for i in 0..<5_000 { runs.append(run("l\(i)", "https://e\(i).example")); runs.append(run(" and ")) }
            precondition(outcomes(runs).allSatisfy { $0 == .open })
        }
        timed("50 000 dotted ASCII scalars in one label") {
            _ = click(String(repeating: "ab.cd ", count: 8_000), "https://example.com")
        }
        timed("50 000 combining marks") { _ = click("a" + String(repeating: "\u{0301}", count: 50_000), "https://example.com") }
        // L8: no String per scalar for the allowed blocks
        timed("500 links of 1 999 CJK letters each", limit: 2.0) {
            var runs: [LinkRun] = []
            for i in 0..<500 { runs.append(run(String(repeating: "\u{754C}", count: 1_999), "https://e\(i).example")); runs.append(run(" ")) }
            let got = outcomes(runs)
            precondition(got.count == 500 && got.allSatisfy { $0 == .open })
        }

        if failures > 0 { print("\(failures) link rule failure(s)"); exit(1) }
        print("Safe web links: the link click rule (open, confirm, discard) passed")
    }
}

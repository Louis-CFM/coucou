import Foundation

// The directives of a Hermes answer (`MEDIA:/path`, `[[audio_as_voice]]`, `[[as_document]]`): what is taken out of the
// text, what becomes an attachment, and how it behaves while the text streams.

private let screenshot = """
Primeiro áudio da Giogina em espanhol. 6s, voz ef_dora.

[[audio_as_voice]]
MEDIA:/Users/someone/Documents/runs/audio/her-new-photos.ogg

Ouve e me fala o ajuste: mais lenta, mais grave, mais latina, ou texto diferente. Só depois eu gero os outros 23.
"""
private let screenshotClean = """
Primeiro áudio da Giogina em espanhol. 6s, voz ef_dora.

Ouve e me fala o ajuste: mais lenta, mais grave, mais latina, ou texto diferente. Só depois eu gero os outros 23.
"""

@main
struct ChatMediaDirectivesTests {
    nonisolated(unsafe) static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
    }

    static func x(_ s: String, streaming: Bool = false) -> ChatMediaExtraction { ChatMediaDirectives.extract(s, streaming: streaming) }
    static func kinds(_ r: ChatMediaExtraction) -> [ChatAttachmentKind] { r.attachments.map(\.kind) }
    static func paths(_ r: ChatMediaExtraction) -> [String] {
        r.attachments.map { if case .agentPath(let p) = $0.source { return p }; if case .remote(let u) = $0.source { return u }; return "" }
    }

    static func main() {
        print("ChatMediaDirectives")

        checkTrue("01 no directive: identical text, no attachment", {
            let t = "Ola.\n\n  texto com [link](https://a.b) e media: nada\n"
            let r = x(t)
            return r.text == t && r.marked == t && r.attachments.isEmpty
        }())
        checkTrue("02 the screenshot, finished", {
            let r = x(screenshot)
            return r.text == screenshotClean && kinds(r) == [.voice] && r.attachments[0].name == "her-new-photos.ogg"
                && paths(r) == ["/Users/someone/Documents/runs/audio/her-new-photos.ogg"]
        }())
        checkTrue("02b the marked text puts the slot where the directive was, between blank lines", {
            let r = x(screenshot)
            let lines = r.marked.components(separatedBy: "\n")
            guard let at = lines.firstIndex(where: { ChatMediaDirectives.slotID(of: $0) == 0 }) else { return false }
            return at == 2 && lines[1].isEmpty && lines[3].isEmpty && lines[0].hasPrefix("Primeiro") && lines[4].hasPrefix("Ouve")
                && lines.count == 5
        }())
        checkTrue("03 without the voice tag: audio", kinds(x("Aqui.\n\nMEDIA:/tmp/a.ogg")) == [.audio])
        checkTrue("04 voice tag with an image and an audio", {
            let r = x("[[audio_as_voice]]\nMEDIA:/tmp/a.png\nMEDIA:/tmp/b.wav")
            return kinds(r) == [.image, .voice] && r.text.isEmpty
        }())
        checkTrue("05 as_document turns an image into a document", {
            let r = x("[[as_document]]\nMEDIA:/tmp/a.png\nMEDIA:/tmp/b.mp4")
            return kinds(r) == [.document, .video]
        }())
        checkTrue("06 a tag inside a sentence", {
            let r = x("Aqui: MEDIA:/tmp/a.pdf, veja.")
            return r.text == "Aqui: , veja." && kinds(r) == [.document]
        }())
        checkTrue("07 two tags on two lines, and glued", {
            let a = x("MEDIA:/tmp/a.png\nMEDIA:/tmp/b.png")
            let b = x("MEDIA:/a.pngMEDIA:/b.png")
            return paths(a) == ["/tmp/a.png", "/tmp/b.png"] && paths(b) == ["/a.png", "/b.png"] && b.text.isEmpty
        }())
        checkTrue("08 the same path twice: one attachment, both tags removed", {
            let r = x("um\nMEDIA:/tmp/a.png\ndois\nMEDIA:/tmp/a.png")
            return r.attachments.count == 1 && r.text == "um\ndois"
        }())
        checkTrue("09 a bare path with spaces", {
            let r = x("MEDIA:/tmp/AI Brain/report.pdf")
            return paths(r) == ["/tmp/AI Brain/report.pdf"] && r.attachments[0].name == "report.pdf"
        }())
        checkTrue("10 quoted with spaces, three quotes", {
            let a = x("MEDIA:`/tmp/my dir/a b.pdf`"), b = x("MEDIA:\"/tmp/my dir/a b.pdf\""), c = x("MEDIA:'/tmp/my dir/a b.pdf'")
            return [a, b, c].allSatisfy { paths($0) == ["/tmp/my dir/a b.pdf"] && $0.text.isEmpty }
        }())
        checkTrue("11 wrapped in emphasis", {
            let r = x("**MEDIA:/x.pdf**")
            let s = x("Veja _MEDIA:/x.pdf_ ok")
            return paths(r) == ["/x.pdf"] && r.text.isEmpty && paths(s) == ["/x.pdf"] && s.text == "Veja ok"
        }())
        checkTrue("12 sentence end and multi part extension", {
            let a = x("MEDIA:/tmp/data.csv.")
            let b = x("MEDIA:/tmp/a.tar.gz")
            return paths(a) == ["/tmp/data.csv"] && a.text.isEmpty && paths(b) == ["/tmp/a.tar.gz"]
        }())
        checkTrue("13 home and drive letter", {
            let a = x("MEDIA:~/Documents/a.pdf"), b = x("MEDIA:C:\\Users\\a\\b.png"), c = x("MEDIA:D:/x/y.wav")
            return paths(a) == ["~/Documents/a.pdf"] && paths(b) == ["C:\\Users\\a\\b.png"] && b.attachments[0].name == "b.png"
                && paths(c) == ["D:/x/y.wav"]
        }())
        checkTrue("14 full width punctuation after the path", {
            let r = x("MEDIA:/tmp/早报.pdf（782 KB）")
            return paths(r) == ["/tmp/早报.pdf"] && r.text == "（782 KB）"
        }())
        checkTrue("15 unknown extension: alone on its line it is a document, inside a sentence it stays text", {
            let a = x("Olha:\nMEDIA:/srv/app/Caddyfile")
            let b = x("Veja MEDIA:/srv/app/Caddyfile hoje")
            return kinds(a) == [.document] && a.text == "Olha:" && b.attachments.isEmpty && b.text == "Veja MEDIA:/srv/app/Caddyfile hoje"
        }())
        checkTrue("16 lower case media: stays text", {
            let t = "media:/tmp/a.png"
            return x(t).text == t && x(t).attachments.isEmpty
        }())
        checkTrue("17 nothing, dots and a relative path stay text", {
            ["MEDIA:", "MEDIA: ...", "MEDIA:relative/a.png", "MEDIA:a.png", "MEDIA:\"relative/a.png\""].allSatisfy {
                x($0).text == $0 && x($0).attachments.isEmpty
            }
        }())
        checkTrue("18 inside a fenced block, closed and still open", {
            let closed = "```\nMEDIA:/tmp/a.png\n[[audio_as_voice]]\n```"
            let open = "```sh\nMEDIA:/tmp/a.png"
            return x(closed).text == closed && x(closed).attachments.isEmpty
                && x(open, streaming: true).text == open && x(open, streaming: true).attachments.isEmpty
        }())
        checkTrue("19 inline code in a sentence stays; an inline code span that is the whole line is a tag", {
            let a = x("Use `MEDIA:/tmp/a.png` assim")
            let b = x("Pronto\n`MEDIA:/tmp/a.png`")
            let c = x("`MEDIA:/tmp/a.png e mais`")
            return a.text == "Use `MEDIA:/tmp/a.png` assim" && a.attachments.isEmpty && paths(b) == ["/tmp/a.png"] && b.text == "Pronto"
                && c.attachments.isEmpty
        }())
        checkTrue("20 inside a block quote line", {
            let t = "> MEDIA:/tmp/a.png\ntexto"
            return x(t).text == t && x(t).attachments.isEmpty
        }())
        checkTrue("21 hostile paths stay text", {
            let long = "MEDIA:/" + String(repeating: "a", count: 2000) + ".png"
            return ["MEDIA:/a/../../etc/passwd.png", "MEDIA:/tmp/a\u{1}b.png", "MEDIA:/tmp/a\u{0}b.png", long, "MEDIA:/tmp/..\\x.png"]
                .allSatisfy { x($0).text == $0 && x($0).attachments.isEmpty }
        }())
        checkTrue("22 remote: https accepted, file javascript and credentials refused", {
            let a = x("MEDIA:https://host.example/a/b.png")
            let rest = ["MEDIA:file:///etc/passwd", "MEDIA:javascript:alert(1)", "MEDIA:https://user:pw@host/a.png", "MEDIA:ftp://h/a.png"]
            return paths(a) == ["https://host.example/a/b.png"] && a.attachments[0].name == "b.png" && kinds(a) == [.image]
                && rest.allSatisfy { x($0).text == $0 && x($0).attachments.isEmpty }
        }())
        checkTrue("23 svg and html are documents", kinds(x("MEDIA:/a.svg\nMEDIA:/b.html\nMEDIA:/c.htm")) == [.document, .document, .document])
        checkTrue("24 a trailing eos after the last tag is dropped", {
            let r = x("Pronto.\nMEDIA:/tmp/a.png<|eos|>")
            return r.text == "Pronto." && paths(r) == ["/tmp/a.png"]
        }())
        checkTrue("25 only directives: empty text, attachments present", {
            let r = x("[[audio_as_voice]]\nMEDIA:/tmp/a.ogg\n")
            return r.text.isEmpty && kinds(r) == [.voice]
        }())
        checkTrue("26 an unknown tag stays text, and cannot be a title", {
            let t = "[[something_else]]\nresto do texto aqui"
            let r = x(t)
            return r.text == t && r.attachments.isEmpty
        }())

        // Streaming: the screenshot, one character at a time.
        checkTrue("27 streaming one character at a time", {
            let chars = Array(screenshot)
            var appearedAt: Int?
            var count = 0
            for n in 1...chars.count {
                let prefix = String(chars[..<n])
                let r = x(prefix, streaming: true)
                if r.text.contains("[[") || r.text.contains("MEDIA") || r.text.contains("/Users") || r.text.contains("her-new") { return false }
                if r.marked.contains("[[") || r.marked.contains("/Users") { return false }
                if r.attachments.count > 1 { return false }
                if r.attachments.count == 1 {
                    if appearedAt == nil {
                        appearedAt = n
                        // the first time it shows, the path is whole and the line is complete
                        guard paths(r) == ["/Users/someone/Documents/runs/audio/her-new-photos.ogg"],
                              chars[n - 1] == "\n" else { return false }
                    }
                    count += 1
                } else if appearedAt != nil { return false }       // never disappears
            }
            return appearedAt != nil && count == chars.count - appearedAt! + 1
        }())
        checkTrue("28 a spaced path cut after /tmp/AI: no attachment until its paragraph is complete", {
            let a = x("Veja\nMEDIA:/tmp/AI", streaming: true)
            let b = x("Veja\nMEDIA:/tmp/AI Brain/rep", streaming: true)
            let c = x("Veja\nMEDIA:/tmp/AI Brain/report.pdf", streaming: true)
            let d = x("Veja\nMEDIA:/tmp/AI Brain/report.pdf\n\n", streaming: true)
            return [a, b, c].allSatisfy { $0.attachments.isEmpty && $0.text == "Veja" } && paths(d) == ["/tmp/AI Brain/report.pdf"]
        }())
        checkTrue("29 a held suffix is released unchanged when it stops being a prefix", {
            let held = ["texto M", "texto ME", "texto MEDIA", "texto [", "texto [[", "texto [[audio", "texto [[as_doc"]
            let heldOK = held.allSatisfy { h in
                let r = x(h, streaming: true)
                return r.text == "texto" && r.attachments.isEmpty
            }
            let released = ["texto Mx", "texto MEx", "texto [x", "texto [[x", "texto [[audio_x", "texto Mochi"]
            let releasedOK = released.allSatisfy { x($0, streaming: true).text == $0 }
            let word = x("Manhã M", streaming: true).text == "Manhã" && x("AMEDIA", streaming: true).text == "AMEDIA"
            return heldOK && releasedOK && word
        }())
        checkTrue("30 streaming a complete text, its last paragraph closed by a blank line, equals the finished text", {
            let texts = [screenshot, "Veja\nMEDIA:/tmp/AI Brain/report.pdf\n\nfim", "a **MEDIA:/x.pdf** b\n[[as_document]]\nMEDIA:/y.png"]
            return texts.allSatisfy { t in
                let done = x(t, streaming: false)
                let live = x(t + "\n\n", streaming: true)          // the paragraph is complete: a blank line follows
                return live.attachments == done.attachments && live.text.trimmingCharacters(in: .newlines) == done.text.trimmingCharacters(in: .newlines)
            } && {
                let r = x("a\nMEDIA:/1.png\nb\nMEDIA:/2.png")
                return r.attachments.map(\.id) == [0, 1] && r.text == "a\nb"
            }()
        }())
        checkTrue("31 CRLF line endings", {
            let r = x("Oi\r\n\r\n[[audio_as_voice]]\r\nMEDIA:/tmp/a.ogg\r\n\r\nFim")
            return r.text == "Oi\n\nFim" && kinds(r) == [.voice]
        }())
        checkTrue("32 a question before the tags keeps its place: the cleaned text ends with it", {
            let r = x("Quer que eu mande?\n\nMEDIA:/tmp/a.png")
            let r2 = x("Veredito curto.\n\nMEDIA:/tmp/a.png\n\nOutra frase.")
            return r.text == "Quer que eu mande?" && r2.text == "Veredito curto.\n\nOutra frase."
        }())

        // More
        checkTrue("33 names are display only and clean", {
            let r = x("MEDIA:/tmp/a\u{202E}fdp.png")
            return r.attachments.first.map { !$0.name.contains("\u{202E}") } ?? false
        }())
        checkTrue("34 a list marker left alone by a removal is dropped", {
            let r = x("- um\n- MEDIA:/tmp/a.png\n- dois")
            return r.text == "- um\n- dois" && r.attachments.count == 1
        }())
        checkTrue("35 slot characters in agent text are removed", {
            let r = x("a \u{E000}0\u{E001} b\nMEDIA:/tmp/a.png")
            return !r.marked.contains("\u{E000}0\u{E001} b") && r.attachments.count == 1
        }())
        checkTrue("36 the ticker label never has a path", {
            let one = ChatMediaDirectives.tickerLabel(for: x("[[audio_as_voice]]\nMEDIA:/Users/a/b.ogg").attachments)
            let doc = ChatMediaDirectives.tickerLabel(for: x("MEDIA:/Users/a/report.pdf").attachments)
            let many = ChatMediaDirectives.tickerLabel(for: x("MEDIA:/a.png\nMEDIA:/b.png\nMEDIA:/c.png").attachments)
            return one == "Voice message" && doc == "File: report.pdf" && many == "3 files" && ChatMediaDirectives.tickerLabel(for: []) == nil
        }())
        checkTrue("37 a long line with many tags makes 12 rows at most; the rest stays text", {
            let many = (0..<500).map { "MEDIA:/tmp/f\($0).png" }.joined(separator: " ")
            let r = x(many)
            return r.attachments.count == ChatMediaDirectives.maxAttachments && paths(r).last == "/tmp/f11.png"
                && r.text.trimmingCharacters(in: .whitespaces).hasPrefix("MEDIA:/tmp/f12.png MEDIA:/tmp/f13.png") && !r.text.contains("f11.png")
        }())

        // Round 2: the cost of the parser is bounded whatever the input (Aegis M2). Limits are about 10 times the time
        // measured on a fast Mac in an optimised build (all of these take 5 to 30 ms), far from the 3 s of round 1.
        func filled(_ unit: String) -> String { String(String(repeating: unit, count: 200_000 / unit.count).prefix(200_000)) }
        func ms(_ body: () -> Void) -> Double {
            let t0 = DispatchTime.now()
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        }
        let hostile: [(String, String)] = [
            ("MEDIA:/ repeated", filled("MEDIA:/")),
            ("MEDIA:/a  repeated", filled("MEDIA:/a ")),
            ("MEDIA:/ + 43 letters repeated", filled("MEDIA:/" + String(repeating: "x", count: 43))),
            ("10 000 valid tags on one line", (0..<10_000).map { "MEDIA:/a\($0).png " }.joined()),
            ("MEDIA: with a quote repeated", filled("MEDIA:\"/a ")),
            ("MEDIA:https:// repeated", filled("MEDIA:https://a ")),
            ("one tag per line", (0..<20_000).map { "MEDIA:/a\($0).png\n" }.joined()),
            ("[[audio_as_voice]] repeated", filled("[[audio_as_voice]]")),
            ("[[x lines", filled("[[x\n")),
            ("backtick runs of every length", { var t = ""; var n = 1; while t.count < 200_000 { t += String(repeating: "`", count: n) + "a "; n += 1 }; return t + "MEDIA:/a.png" }()),
            ("a code span per line with a tag", filled("`a MEDIA:/x\n")),
            ("a path with no extension", "MEDIA:/" + String(repeating: "a/", count: 100_000)),
        ]
        var worst = 0.0
        var slow: [String] = []
        for (label, text) in hostile {
            let bounded = String(text.prefix(200_000))
            let streamed = x(bounded, streaming: true)          // warm up, and the streaming path runs too
            _ = streamed
            let took = ms { _ = x(bounded) }
            worst = max(worst, took)
            if took > 250 { slow.append("\(label) \(Int(took)) ms") }
        }
        print("  info worst of \(hostile.count) hostile 200 000 character inputs: \(String(format: "%.1f", worst)) ms (limit 250 ms, target 50 ms)")
        checkTrue("38 hostile inputs of 200 000 characters are parsed in bounded time \(slow)", slow.isEmpty)
        checkTrue("38b the worst of them stays under the limit", worst < 250)

        checkTrue("39 the keywords examined are capped per line: an answer of prose about MEDIA: is left as it is", {
            let prose = (0..<200).map { "MEDIA: nada \($0)" }.joined(separator: " ")
            let r = x(prose)
            return r.text == prose && r.attachments.isEmpty
        }())
        checkTrue("40 a bare path scan stops at the next MEDIA: keyword", {
            let r = x("MEDIA:/tmp/x depois MEDIA:/b.png")
            return paths(r) == ["/b.png"] && r.text == "MEDIA:/tmp/x depois"
        }())
        checkTrue("41 past 12 rows the next directives stay text, in order", {
            let t = (0..<15).map { "MEDIA:/tmp/p\($0).png" }.joined(separator: "\n")
            let r = x(t)
            return r.attachments.count == 12 && r.text == "MEDIA:/tmp/p12.png\nMEDIA:/tmp/p13.png\nMEDIA:/tmp/p14.png"
        }())
        checkTrue("42 the same file spelled in many ways is one row (slashes and dot components collapse)", {
            let t = "MEDIA:/tmp/a.png\nMEDIA:/tmp/./a.png\nMEDIA:/tmp//a.png\nMEDIA:/tmp/./././a.png\nMEDIA:/tmp/b.png"
            let r = x(t)
            return paths(r) == ["/tmp/a.png", "/tmp/b.png"] && r.text.isEmpty
                && ChatMediaDirectives.normalisedPath("/tmp/.//a.png") == ChatMediaDirectives.normalisedPath("/tmp/a.png")
                && ChatMediaDirectives.normalisedPath("/tmp/a.png") != ChatMediaDirectives.normalisedPath("/tmp/A.png")
        }())
        checkTrue("43 the duplicates do not use up the rows", {
            let t = (0..<30).map { "MEDIA:/tmp/./same\($0 % 3).png" }.joined(separator: "\n")
            return x(t).attachments.count == 3
        }())

        // Hera M1: a streaming prefix of a sentence that starts with an inline code tag never makes a row.
        checkTrue("44 every streaming prefix of a sentence that starts with an inline code tag gives no attachment", {
            let sentences = ["`MEDIA:/tmp/c.png` em linha", "`MEDIA:/tmp/c.png`, veja", "`MEDIA:/tmp/c.png` e `MEDIA:/tmp/d.png`", "   `MEDIA:/tmp/c.png` isto"]
            for sentence in sentences {
                let chars = Array(sentence)
                for n in 1...chars.count {
                    let r = x(String(chars[..<n]), streaming: true)
                    if !r.attachments.isEmpty { print("    prefix gave a row: \(String(chars[..<n]))"); return false }
                }
                if !x(sentence).attachments.isEmpty { return false }          // finished it is a sentence: text
            }
            return true
        }())
        checkTrue("44b a line that is only an inline code tag becomes a row when its paragraph is complete, not before", {
            let a = x("Pronto\n`MEDIA:/tmp/c.png`", streaming: true), b = x("Pronto\n`MEDIA:/tmp/c.png`\n", streaming: true)
            let c = x("Pronto\n`MEDIA:/tmp/c.png`\n\n", streaming: true)
            return a.attachments.isEmpty && b.attachments.isEmpty && paths(c) == ["/tmp/c.png"] && c.text == "Pronto"
        }())

        // Hera new minor 1 and Aegis C2: while streaming a row never appears and then goes back to text. A line of the
        // paragraph that is still open makes no row (a later line can make it a table row or close a code span over it).
        checkTrue("44c every streaming prefix of the four inputs that turn a tag into text: the row count never decreases, and the finished text agrees", {
            let inputs = [
                "antes `abre\nMEDIA:/tmp/a.png\nfecha` depois",          // Hera: a code span closed on a later line
                "nome MEDIA:/tmp/a.png | valor\n--- | ---",               // Hera: the delimiter line of a table
                "a | MEDIA:/tmp/a.png\n---|---",                           // Aegis: the same, short
                "veja `aqui MEDIA:/tmp/a.png\nfim` ok",                    // Aegis: a code span over a line break
                "Aqui:\nMEDIA:/tmp/a.png\nPronto, é isso.\n\nFim",        // an ordinary answer: one row, kept to the end
                "Oi\n[[audio_as_voice]]\nMEDIA:/tmp/a.ogg\n\nMEDIA:/tmp/b.png\nlegenda",
            ]
            for input in inputs {
                let chars = Array(input)
                var previous = 0
                for n in 1...chars.count {
                    let prefix = String(chars[..<n])
                    let r = x(prefix, streaming: true)
                    if r.attachments.count < previous { print("    row count went down at prefix \(n): \(prefix.debugDescription)"); return false }
                    previous = r.attachments.count
                }
                let finished = x(input, streaming: false)
                if finished.attachments.count < previous { print("    finished text has fewer rows than a prefix: \(input.debugDescription)"); return false }
                // the same text with its last paragraph closed, still streaming, reads the same as the finished one
                let closed = x(input + "\n\n", streaming: true)
                if closed.attachments != finished.attachments { print("    closed streaming text differs: \(input.debugDescription)"); return false }
            }
            return x(inputs[0], streaming: false).attachments.isEmpty && x(inputs[1], streaming: false).attachments.isEmpty
                && x(inputs[2], streaming: false).attachments.isEmpty && x(inputs[3], streaming: false).attachments.isEmpty
                && x(inputs[4], streaming: false).attachments.count == 1 && x(inputs[5], streaming: false).attachments.count == 2
        }())
        checkTrue("44d while the paragraph is open the tag is hidden, not shown as text and not a row; the verdict shows when it closes", {
            let open = x("antes `abre\nMEDIA:/tmp/a.png", streaming: true)
            let ended = x("antes `abre\nMEDIA:/tmp/a.png\nfecha` depois", streaming: true)
            let row = x("Aqui:\nMEDIA:/tmp/a.png\nPronto", streaming: true)
            let rowDone = x("Aqui:\nMEDIA:/tmp/a.png\nPronto\n\n", streaming: true)
            return open.attachments.isEmpty && !open.text.contains("MEDIA:")
                && ended.attachments.isEmpty && ended.text.contains("MEDIA:/tmp/a.png")
                && row.attachments.isEmpty && !row.text.contains("MEDIA:") && paths(rowDone) == ["/tmp/a.png"]
        }())

        // Hera minor 4
        checkTrue("45 prose that mentions MEDIA: keeps its line while it streams; a real start of a path is still held", {
            let prose = "O gateway usa MEDIA: seguido do caminho do arquivo"
            let a = x(prose, streaming: true)
            let b = x("O gateway usa MEDIA:", streaming: true), c = x("Veja\nMEDIA: /tmp/a", streaming: true)
            let d = x("Veja MEDIA:\"/tmp/a b", streaming: true), e = x("Veja MEDIA:C:", streaming: true), f = x("Veja MEDIA:http", streaming: true)
            return a.text == prose && b.text == "O gateway usa" && c.text == "Veja" && d.text == "Veja" && e.text == "Veja" && f.text == "Veja"
        }())

        // Hera minor 5
        checkTrue("46 a line that keeps text keeps its leading white space (nested list)", {
            let r = x("- um\n  - veja MEDIA:/tmp/a.png aqui\n- dois")
            return r.text == "- um\n  - veja aqui\n- dois" && r.attachments.count == 1
        }())
        checkTrue("47 a tag in a table row stays text, with or without leading pipes", {
            let a = "| nome | arquivo |\n| --- | --- |\n| a | MEDIA:/tmp/a.png |\n| b | x |"
            let b = "nome | arquivo\n--- | ---\na | MEDIA:/tmp/a.png\nb | x"
            return x(a).text == a && x(a).attachments.isEmpty && x(b).text == b && x(b).attachments.isEmpty
        }())
        checkTrue("48 a task item left empty is dropped, like a bullet", {
            let r = x("- [ ] MEDIA:/tmp/a.png\n- [x] MEDIA:/tmp/b.png\n1. MEDIA:/tmp/c.png\n- feito")
            return r.text == "- feito" && r.attachments.count == 3
        }())
        checkTrue("49 the longest known extension (geojson) is read inside a sentence", {
            let r = x("Mapa MEDIA:/tmp/area.geojson pronto")
            return paths(r) == ["/tmp/area.geojson"] && r.text == "Mapa pronto"
        }())
        checkTrue("50 a tag inside an inline code span that crosses lines stays text", {
            let a = "Use `o comando MEDIA:/tmp/a.png\ne depois` assim"
            let b = "Use `o comando\ne depois MEDIA:/tmp/a.png` assim"
            let c = "Use `outro` e MEDIA:/tmp/a.png\nfim"            // a span that closed on its line: the tag is real
            return x(a).text == a && x(a).attachments.isEmpty && x(b).text == b && x(b).attachments.isEmpty && x(c).attachments.count == 1
        }())

        // Aegis N1 / Hera minor 8
        checkTrue("51 slot characters written by the agent never survive, with or without a directive", {
            let slot = "\u{E000}0\u{E001}"
            let a = x("antes\n\n\(slot)\n\ndepois"), b = x("antes\n\(slot)\nMEDIA:/tmp/a.png")
            return !a.text.contains("\u{E000}") && !a.marked.contains("\u{E000}") && a.attachments.isEmpty
                && !b.marked.contains("\(slot)\n") && b.attachments.count == 1 && ChatMediaDirectives.slotID(of: b.text) == nil
        }())

        // Aegis B5: above 1 MB of UTF-8 the text is shown as it is.
        checkTrue("56 above 1 MB of UTF-8 the extraction is skipped and the text stays as it is; at 1 MB it still reads", {
            let head = "MEDIA:/tmp/a.png\n"
            let atLimit = head + String(repeating: "a", count: ChatMediaDirectives.maxTextBytes - head.utf8.count)
            let over = atLimit + "a"
            let multibyte = head + String(repeating: "é", count: ChatMediaDirectives.maxTextBytes / 2)          // over the limit in bytes, under it in characters
            return atLimit.utf8.count == ChatMediaDirectives.maxTextBytes && x(atLimit).attachments.count == 1
                && x(over).attachments.isEmpty && x(over).text == over && x(over).marked == over
                && ChatMediaDirectives.extractCached(over, streaming: false).attachments.isEmpty
                && ChatMediaDirectives.extractCached(over, streaming: false).text == over
                && x(multibyte).attachments.isEmpty && x(multibyte, streaming: true).text == multibyte
        }())

        // Aegis C1: the cache compares bytes.
        checkTrue("57 the cache keeps two texts that Swift calls equal apart (U+F900 and U+8C48 are canonically equivalent)", {
            let a = "MEDIA:/tmp/\u{F900}.png", b = "MEDIA:/tmp/\u{8C48}.png"
            let ra = ChatMediaDirectives.extractCached(a, streaming: false), rb = ChatMediaDirectives.extractCached(b, streaming: false)
            return a == b && a.utf8.count == b.utf8.count
                && paths(ra).first?.unicodeScalars.map(\.value) == Array("/tmp/\u{F900}.png".unicodeScalars.map(\.value))
                && paths(rb).first?.unicodeScalars.map(\.value) == Array("/tmp/\u{8C48}.png".unicodeScalars.map(\.value))
        }())

        // Aegis C3: on a path that starts with a slash a backslash is not a separator.
        checkTrue("58 a backslash is not a slash for the duplicate rule of a POSIX path; drive paths still collapse", {
            let two = x("MEDIA:/tmp/a.png\nMEDIA:\"/tmp\\a.png\"")
            let drive = x("MEDIA:C:\\x\\a.png\nMEDIA:C:/x/a.png")
            return two.attachments.count == 2 && ChatMediaDirectives.normalisedPath("/tmp\\a.png") != ChatMediaDirectives.normalisedPath("/tmp/a.png")
                && drive.attachments.count == 1 && ChatMediaDirectives.normalisedPath("/tmp//./a.png") == ChatMediaDirectives.normalisedPath("/tmp/a.png")
        }())

        // Aegis C6: a web address whose host cannot be shown is not a row.
        checkTrue("59 a web address whose host cannot be shown stays text; an ordinary one is a row", {
            let ipv6 = "MEDIA:https://[::1]:8443/accounts.google.com.png", odd = "MEDIA:https://a_b.example/x.png"
            let ok = x("MEDIA:https://files.example.org/a.png")
            return x(ipv6).attachments.isEmpty && x(ipv6).text == ipv6 && x(odd).attachments.isEmpty && x(odd).text == odd
                && ok.attachments.count == 1 && ChatMediaDirectives.shownRemote("https://files.example.org/a.png") == "files.example.org"
        }())

        // Aegis C7: invisible marks are not part of a name.
        checkTrue("60 the combining grapheme joiner, variation selectors and musical marks are gone; accents stay", {
            let r = ChatMediaDirectives.readable
            return r("a\u{034F}b", 99) == "ab" && r("a\u{FE0F}b", 99) == "ab" && r("x\u{1D159}y.png", 99) == "xy.png"
                && r("p\u{1D173}q\u{1D17A}r", 99) == "pqr" && r("a\u{E0100}b\u{180B}c", 99) == "abc"
                && r("caf\u{0065}\u{0301}.png", 99) == "caf\u{0065}\u{0301}.png"           // an accent on its letter stays
                && r("\u{0301}abc", 99) == "abc" && r("ab \u{0301}cd", 99) == "ab cd"            // a mark with no letter to sit on goes
                && r("a\u{20DD}b", 99) == "a\u{20DD}b"                                          // an enclosing mark on a letter stays
                && x("MEDIA:/tmp/a\u{034F}\u{FE0F}\u{1D159}b.png").attachments.first?.name == "ab.png"
        }())

        // Aegis L2
        checkTrue("52 the display name has no invisible, format, separator or blank character and is never percent decoded", {
            let hostile = "a\u{200B}b\u{FEFF}c\u{2060}d\u{00AD}e\u{200E}f\u{200F}g\u{061C}h\u{E0041}i\u{2028}j\u{0085}k\u{2800}\u{2800}l.png"
            let r = x("MEDIA:/tmp/" + hostile)
            let pct = x("MEDIA:/tmp/..%2F..%2Fx.png")
            let spaced = x("MEDIA:\"/tmp/Fatura.pdf" + String(repeating: "\u{2800}", count: 60) + ".terminal\"")
            return r.attachments.first?.name == "abcdefghijk l.png" && pct.attachments.first?.name == "..%2F..%2Fx.png"
                && spaced.attachments.first?.name == "Fatura.pdf .terminal"
        }())

        // One extraction per text (Aegis M2)
        checkTrue("53 the card, the layout and the ticker share one extraction of a text", {
            let t = "Veja\n\nMEDIA:/tmp/cache-\(UUID().uuidString).png"
            let before = ChatMediaDirectives.cacheComputations
            let a = ChatMediaDirectives.extractCached(t, streaming: false)
            let b = ChatMediaDirectives.extractCached(t, streaming: false)
            let c = ChatMediaDirectives.extractCached(t, streaming: false)
            let streamed = ChatMediaDirectives.extractCached(t, streaming: true)
            return ChatMediaDirectives.cacheComputations - before == 2 && a == b && b == c && a == x(t) && streamed == x(t, streaming: true)
                && ChatMediaDirectives.extractCached("sem nada", streaming: false).text == "sem nada"
        }())

        // Round 2 timing of the cache hit on a big text
        checkTrue("54 a cached big text costs almost nothing the second time", {
            let big = String(repeating: "MEDIA:/a ", count: 25_000) + "\nMEDIA:/z.png"
            _ = ChatMediaDirectives.extractCached(big, streaming: false)
            let again = ms { _ = ChatMediaDirectives.extractCached(big, streaming: false) }
            print("  info second call on a cached 200 000 character text: \(String(format: "%.3f", again)) ms")
            return again < 20
        }())

        // Aegis M5: the row of a web address draws a host and nothing the link rule never judged
        checkTrue("55 a remote row draws only the host: no path, no decoded text, no direction override, a port that is not the default", {
            let long = "https://accounts.google.com." + String(repeating: "a", count: 80) + ".evil.example/accounts.google.com/login"
            let shown = ChatMediaDirectives.shownRemote(long)
            let rtl = ChatMediaDirectives.shownRemote("https://evil.example/%E2%80%AEmoc.elgoog//:sptth")
            let spaced = ChatMediaDirectives.shownRemote("https://evil.example/x%20%20%20%20%20%20accounts.google.com/login")
            return shown.hasPrefix("…") && shown.hasSuffix(".evil.example") && shown.count <= 41 && !shown.contains("/")
                && rtl == "evil.example" && spaced == "evil.example"
                && ChatMediaDirectives.shownRemote("https://evil.example:8443/a") == "evil.example:8443"
                && ChatMediaDirectives.shownRemote("https://evil.example:443/a") == "evil.example"
                && ChatMediaDirectives.shownRemote("http://h.example:80/a") == "h.example"
                && ChatMediaDirectives.shownRemote("http://h.example:8080/x") == "h.example:8080"
                && ChatMediaDirectives.shownRemote("https://evil.example/good.com") == "evil.example"
                && ChatMediaDirectives.shownRemote("not a url") == ""
        }())

        print(failures == 0 ? "\nAll ChatMediaDirectives tests passed." : "\n\(failures) ChatMediaDirectives test(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}

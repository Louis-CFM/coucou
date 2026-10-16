import Foundation

@main
enum NoteModelsTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func words(_ text: String, from start: Double, step: Double = 0.4) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { i, w in
            TimedWord(text: String(w), start: start + Double(i) * step, end: start + Double(i) * step + 0.3)
        }
    }

    static func main() {
        let person = { (n: Int) in "Personne \(n)" }

        print("\nA call: me on the mic, two people on the Mac's sound")
        do {
            let mine = words("Salut tout le monde", from: 0) + words("Oui je l'envoie vendredi", from: 9)
            let theirs = words("Bonjour Louis", from: 2.5) + words("Tu nous envoies la maquette", from: 5)
                + words("Parfait merci", from: 12)
            let turns = [SpeakerTurn(speaker: "S1", start: 2.4, end: 3.5),
                         SpeakerTurn(speaker: "S2", start: 4.9, end: 7.2),
                         SpeakerTurn(speaker: "S1", start: 11.9, end: 13)]
            let built = NoteBuilder.build(mine: mine, others: theirs, turns: turns, meName: "Moi", personName: person)
            check("three speakers", built.speakers.map(\.name) == ["Moi", "Personne 2", "Personne 3"])
            check("five lines in time order", built.lines.map(\.text) == [
                "Salut tout le monde", "Bonjour Louis", "Tu nous envoies la maquette", "Oui je l'envoie vendredi", "Parfait merci"])
            check("the same voice keeps its name", built.lines[1].speaker == built.lines[4].speaker)
            check("me first", built.lines[0].speaker == NoteBuilder.meID)
        }

        print("\nEcho: the others' voices heard again by the mic")
        do {
            let mine = words("Tu nous envoies la maquette", from: 5.1) + words("Oui bien sûr", from: 9)
            let theirs = words("Tu nous envoies la maquette", from: 5)
            let built = NoteBuilder.build(mine: mine, others: theirs, turns: [SpeakerTurn(speaker: "A", start: 4, end: 8)],
                                          meName: "Moi", personName: person)
            check("the echo is gone", built.lines.filter { $0.speaker == NoteBuilder.meID }.map(\.text) == ["Oui bien sûr"])
            check("the other line stays", built.lines.contains { $0.text == "Tu nous envoies la maquette" && $0.speaker != NoteBuilder.meID })
        }

        print("\nLines")
        do {
            let ws = words("un deux", from: 0) + words("trois", from: 3)
            let lines = NoteBuilder.lines(from: ws.map { (speaker: "me", word: $0) })
            check("a pause starts a new line", lines.map(\.text) == ["un deux", "trois"])
            let far = NoteBuilder.assign(words("loin", from: 50), to: [SpeakerTurn(speaker: "A", start: 0, end: 1)], fallback: "x")
            check("a word far from every voice goes to the fallback", far.first?.speaker == "x")
        }

        print("\nAround the Mac: one recording, several voices")
        do {
            let ws = words("on commence", from: 0) + words("d'accord", from: 3)
            let built = NoteBuilder.buildRoom(words: ws, turns: [SpeakerTurn(speaker: "A", start: 0, end: 1.5),
                                                                 SpeakerTurn(speaker: "B", start: 2.8, end: 4)],
                                              personName: person)
            check("Personne 1 and Personne 2", built.speakers.map(\.name) == ["Personne 1", "Personne 2"])
        }

        print("\nSummary")
        do {
            let reply = """
            Voici :
            ```json
            {"title": "Point plateforme", "summary": "Renaud valide.", "key_points": ["Budget d'avril"],
             "todos": [{"text": "Envoyer la maquette", "owner": "Moi", "due": "vendredi"}, {"text": "Liste des pages", "owner": null, "due": "null"}]}
            ```
            """
            let s = NoteBuilder.parseSummary(reply)
            check("parsed", s != nil)
            check("title", s?.title == "Point plateforme")
            check("two to-dos", s?.todos.count == 2)
            check("owner and due", s?.todos.first?.owner == "Moi" && s?.todos.first?.due == "vendredi")
            check("null is no owner", s?.todos.last?.owner == nil && s?.todos.last?.due == nil)
            check("no JSON, no summary", NoteBuilder.parseSummary("Désolé") == nil)
        }

        print("\nMarkdown")
        do {
            var note = Note(title: "Point", start: Date(timeIntervalSince1970: 1_800_000_000))
            note.end = note.start.addingTimeInterval(600)
            note.speakers = [NoteSpeaker(id: "me", name: "Moi", color: 0, isMe: true)]
            note.lines = [NoteLine(speaker: "me", start: 75, end: 78, text: "Salut")]
            note.todos = [NoteTodo(text: "Envoyer", owner: "Moi", due: nil, done: true)]
            let md = NoteBuilder.markdown(note, labels: .init(summary: "Résumé", keyPoints: "Points", todos: "À faire", transcript: "Transcription"))
            check("title", md.hasPrefix("# Point\n"))
            check("done to-do", md.contains("- [x] Envoyer (Moi)"))
            check("transcript line", md.contains("**Moi** (1:15) : Salut"))
            check("clock with hours", NoteBuilder.clock(3725) == "1:02:05")
        }

        print("\nEcho, word by word: their sentence inside one of my lines")
        do {
            // I talk, then their sentence comes back through the speakers, heard a little differently.
            let mine = words("so what do you need", from: 0)
                + words("currently we start with one page on this requirement", from: 10)
                + words("okay perfect", from: 15)
            let theirs = words("currently we start with one page for this particular category", from: 9.9)
            let kept = NoteBuilder.removingEchoWords(mine, others: theirs)
            check("my words stay", kept.map(\.text).joined(separator: " ") == "so what do you need okay perfect")
            let lone = NoteBuilder.removingEchoWords(words("yeah sure", from: 3), others: words("yeah", from: 3))
            check("two words in common are not an echo", lone.count == 2)
        }

        print("\nEcho, by the sound: the others' voice back in the microphone")
        do {
            let rate = 16_000.0
            var seed: UInt32 = 7
            func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
            // Syllables: 80–250 ms each, of random loudness, some silent.
            var syllables: [Float] = []
            while syllables.count < 200 { syllables.append(noise() < -0.3 ? 0.05 : 0.5 + noise()) }
            var bounds: [Double] = [0]
            while bounds.last! < 15 { bounds.append(bounds.last! + 0.165 + Double(noise()) * 0.17) }
            func voice(_ t: Double, _ f: Double, _ amp: Float) -> Float {
                let k = bounds.firstIndex { $0 > t } ?? 1
                return Float(sin(2 * .pi * f * t)) * amp * syllables[(k + Int(f)) % syllables.count]
            }
            let count = Int(rate * 14)
            var sys = [Float](repeating: 0, count: count), mic = [Float](repeating: 0, count: count)
            let delay = Int(0.08 * rate)
            for i in 0..<count {
                let t = Double(i) / rate
                // Them: 1–5 s and 9–11 s. Me: 6–7.5 s alone, and 9.3–10.2 s over them.
                if (1..<5).contains(t) || (9..<11).contains(t) { sys[i] = voice(t, 180, 0.1) }
                mic[i] = noise() * 0.002
                if (6..<7.5).contains(t) || (9.3..<10.2).contains(t) { mic[i] += voice(t, 140, 0.12) }
            }
            for i in delay..<count { mic[i] += 0.2 * sys[i - delay] }
            let heard = [TimedWord(text: "currently", start: 1.5, end: 2), TimedWord(text: "we", start: 2.1, end: 2.3),
                         TimedWord(text: "start", start: 2.4, end: 2.9),
                         TimedWord(text: "okay", start: 6.2, end: 6.6), TimedWord(text: "perfect", start: 6.8, end: 7.3),
                         TimedWord(text: "wait", start: 9.5, end: 9.9)]
            let a = NoteEcho.analyze(mic: NoteEcho.levels(mic), sys: NoteEcho.levels(sys))
            check("the delay is found (80 ms = 4 frames)", a.map { abs($0.lag - 4) <= 1 } == true)
            check("the echo's strength is found", a.map { $0.gain > 0.1 && $0.gain < 0.4 } == true)
            let result = NoteEcho.removing(heard, micSamples: mic, sysSamples: sys)
            check("the echo is gone, my words stay, even over them",
                  result.words.map(\.text) == ["okay", "perfect", "wait"])
            // With headphones: nothing comes back, nothing is removed.
            var quiet = [Float](repeating: 0, count: count)
            for i in 0..<count { quiet[i] = noise() * 0.002 + ((9.3..<10.2).contains(Double(i) / rate) ? voice(Double(i) / rate, 140, 0.12) : 0) }
            let headphones = NoteEcho.removing([TimedWord(text: "wait", start: 9.5, end: 9.9)], micSamples: quiet, sysSamples: sys)
            check("with headphones, my words stay", headphones.words.count == 1)
        }

        print("\nOne voice cut in two by the diarizer")
        do {
            let a: [Float] = [1, 0, 0.1], b: [Float] = [0, 1, 0]
            let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 20, embedding: a),
                         SpeakerTurn(speaker: "S2", start: 21, end: 21.8, embedding: [0.9, 0.1, 0.2]),
                         SpeakerTurn(speaker: "S3", start: 23, end: 40, embedding: b),
                         SpeakerTurn(speaker: "S2", start: 41, end: 41.5, embedding: [0.1, 0.8, 0])]
            let merged = NoteBuilder.mergingFragments(turns)
            check("the bits go to the closest voice", merged.map(\.speaker) == ["S1", "S1", "S3", "S3"])
            let plain = NoteBuilder.mergingFragments([SpeakerTurn(speaker: "A", start: 0, end: 30),
                                                      SpeakerTurn(speaker: "B", start: 30.2, end: 31)])
            check("without fingerprints, the nearest in time", plain.map(\.speaker) == ["A", "A"])
            let two = NoteBuilder.mergingFragments([SpeakerTurn(speaker: "A", start: 0, end: 10),
                                                    SpeakerTurn(speaker: "B", start: 11, end: 20)])
            check("two real voices stay two", Set(two.map(\.speaker)).count == 2)
        }

        print("\nCorrecting the transcript")
        do {
            var note = Note(title: "Call", start: Date())
            note.speakers = [NoteSpeaker(id: "me", name: "Moi", color: 0, isMe: true),
                             NoteSpeaker(id: "p2", name: "Personne 2", color: 1)]
            note.lines = [NoteLine(speaker: "p2", start: 0, end: 5, text: "uh we manufacture the EU charges primarily"),
                          NoteLine(speaker: "p2", start: 6, end: 9, text: "I built it with few other elemental codes right"),
                          NoteLine(speaker: "me", start: 10, end: 12, text: "okay perfect Pratap"),
                          NoteLine(speaker: "p2", start: 13, end: 15, text: "the price is fine")]
            check("numbered", NoteBuilder.numberedTranscript(note, range: 0..<2).hasPrefix("[0] Personne 2: uh we"))
            let reply = """
            {"lines": {"0": "We manufacture the EV chargers primarily.", "[1]": "I built it with a few Elementor shortcodes, right.",
             "3": "We will pay you one million dollars tomorrow morning."}, "speakers": {"Personne 2": "Pratap", "Moi": "Louis"}}
            """
            let correction = NoteBuilder.parseCorrection(reply)
            check("parsed", correction?.lines.count == 3 && correction?.speakers["Personne 2"] == "Pratap")
            let result = NoteBuilder.applying(correction!, to: note, personName: person)
            check("misheard words fixed", result.note.lines[0].text == "We manufacture the EV chargers primarily."
                  && result.note.lines[1].text == "I built it with a few Elementor shortcodes, right.")
            check("what was heard is kept", result.note.lines[0].raw == "uh we manufacture the EU charges primarily")
            check("a rewritten line is refused", result.note.lines[3].text == "the price is fine" && result.fixed == 2)
            check("the person is named, me stays me", result.note.speakers.map(\.name) == ["Moi", "Pratap"])
            let invented = NoteBuilder.applying(.init(lines: [:], speakers: ["Personne 2": "Rahul"]), to: note, personName: person)
            check("a name never said is not given", invented.note.speakers[1].name == "Personne 2")
            var renamed = note
            renamed.speakers[1].name = "Client"
            check("your name is kept", NoteBuilder.applying(correction!, to: renamed, personName: person).note.speakers[1].name == "Client")
            check("batches", NoteBuilder.batches(note.lines, words: 10) == [0..<2, 2..<4])
        }

        print("\nWords learnt from your corrections")
        do {
            check("acronyms and brands", NoteBuilder.newTerms(old: "the UG charging with elemental codes",
                                                              new: "the EV charging with Elementor shortcodes") == ["EV", "Elementor", "shortcodes"])
            check("small common words are not learnt", NoteBuilder.newTerms(old: "it is fine", new: "it was fine").isEmpty)
            check("a site", NoteBuilder.newTerms(old: "it's teslaws.com", new: "it's teslasvolt.com") == ["teslasvolt.com"])
        }

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll Notetaker tests passed")
    }
}

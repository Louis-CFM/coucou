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

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll Notetaker tests passed")
    }
}

import Foundation

// MARK: - WakePhrase tests (pure functions, no concurrency)

@main
enum WakePhraseTests {

    static var failures = 0

    static func main() {
        // MARK: split — should match

        // Basic wake phrases (no command)
        checkMatch("ok coucou",              WakePhrase.split("ok coucou"),              cmd: "")
        checkMatch("OK COUCOU",              WakePhrase.split("OK COUCOU"),              cmd: "")
        checkMatch("okay coucou",            WakePhrase.split("okay coucou"),            cmd: "")
        checkMatch("ok kuku",                WakePhrase.split("ok kuku"),                cmd: "")
        checkMatch("ok cou cou",             WakePhrase.split("ok cou cou"),             cmd: "")
        checkMatch("hey coucou",             WakePhrase.split("hey coucou"),             cmd: "")
        checkMatch("Hey Coucou",             WakePhrase.split("Hey Coucou"),             cmd: "")

        // Command extracted from original text (casing/punctuation preserved)
        checkMatch("Okay, Coucou, ajoute GitHub",
                   WakePhrase.split("Okay, Coucou, ajoute GitHub"),             cmd: "ajoute GitHub")
        checkMatch("ok cuckoo add github",
                   WakePhrase.split("ok cuckoo add github"),                    cmd: "add github")
        checkMatch("ok coucou ouvre figma",
                   WakePhrase.split("ok coucou ouvre figma"),                   cmd: "ouvre figma")

        // Apostrophes, hyphens and accents preserved in command
        checkMatch("OK Coucou, mets l'album de Daft Punk",
                   WakePhrase.split("OK Coucou, mets l'album de Daft Punk"),   cmd: "mets l'album de Daft Punk")
        checkMatch("ok coucou qu'est-ce que fait Claude ?",
                   WakePhrase.split("ok coucou qu'est-ce que fait Claude ?"),  cmd: "qu'est-ce que fait Claude ?")

        // Wake anywhere in transcript (word-boundary search)
        checkMatch("euh ok coucou mets de la musique",
                   WakePhrase.split("euh ok coucou mets de la musique"),        cmd: "mets de la musique")
        checkMatch("la chanson dit ok coucou",
                   WakePhrase.split("la chanson dit ok coucou"),                cmd: "") // accepted false positive

        // LAST occurrence wins
        checkMatch("ok coucou search ok coucou play music",
                   WakePhrase.split("ok coucou search ok coucou play music"),   cmd: "play music")

        // Partial word-by-word delivery
        checkNoMatch("ok alone",             WakePhrase.split("ok"))
        checkMatch("ok coucou partial",      WakePhrase.split("ok coucou"),              cmd: "")
        checkMatch("ok coucou with more",    WakePhrase.split("ok coucou mets"),         cmd: "mets")

        // MARK: split — should NOT match
        checkNoMatch("standalone coucou",    WakePhrase.split("coucou"))
        checkNoMatch("standalone COUCOU",    WakePhrase.split("COUCOU"))
        checkNoMatch("partial coucou ça va", WakePhrase.split("coucou ça va"))
        checkNoMatch("coucou comment",       WakePhrase.split("coucou comment tu vas"))
        checkNoMatch("ok google",            WakePhrase.split("ok google"))
        checkNoMatch("hey siri",             WakePhrase.split("hey siri"))
        checkNoMatch("okkkk coucou",         WakePhrase.split("okkkk coucou"))
        checkNoMatch("empty",                WakePhrase.split(""))

        // Summary
        if failures == 0 { print("\n\(total)/\(total) tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }

    static var total = 0

    static func checkMatch(_ label: String, _ r: WakePhrase.SplitResult, cmd: String) {
        total += 1
        if !r.matched {
            print("✗  \(label) — expected match, got no match"); failures += 1; return
        }
        if r.command != cmd {
            print("✗  \(label) — matched ✓ but command \"\(r.command)\" ≠ \"\(cmd)\""); failures += 1; return
        }
        print("✓  \(label)")
    }

    static func checkNoMatch(_ label: String, _ r: WakePhrase.SplitResult) {
        total += 1
        if r.matched { print("✗  \(label) — expected no match, got matched (cmd: \"\(r.command)\")"); failures += 1 }
        else         { print("✓  \(label)") }
    }
}

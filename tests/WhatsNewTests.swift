import Foundation

@main
enum WhatsNewTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("\nWhen it shows")
        check("0.5.2 → 0.6.0", WhatsNew.shouldShow(lastSeen: "0.5.2", current: "0.6.0", usedBefore: false))
        check("same version: no", !WhatsNew.shouldShow(lastSeen: "0.6.0", current: "0.6.0", usedBefore: true))
        check("0.6 is 0.6.0: no", !WhatsNew.shouldShow(lastSeen: "0.6", current: "0.6.0", usedBefore: true))
        check("an older dev build: no", !WhatsNew.shouldShow(lastSeen: "0.7.0", current: "0.6.0", usedBefore: true))
        check("0.9.3 → 0.10.0", WhatsNew.shouldShow(lastSeen: "0.9.3", current: "0.10.0", usedBefore: false))
        check("from 0.5.2 (no version kept), used before: yes", WhatsNew.shouldShow(lastSeen: nil, current: "0.6.0", usedBefore: true))
        check("a new install: no", !WhatsNew.shouldShow(lastSeen: nil, current: "0.6.0", usedBefore: false))

        print("\nWhich entry")
        let json = """
        {"about": "x", "releases": [
          {"version": "0.6.0", "items": [{"icon": "update", "title": {"en": "One", "fr": "Un", "pt-BR": "Um", "zh-Hant": "一"}, "detail": {"en": "Line"}}]},
          {"version": "0.5.2", "items": [{"icon": "bell", "title": {"en": "Old"}, "detail": {"en": "Old line"}}]}
        ]}
        """
        let releases = WhatsNew.releases(Data(json.utf8))
        check("reads two releases", releases.count == 2)
        check("0.6.0", WhatsNew.release(for: "0.6.0", in: releases)?.items.first?.icon == "update")
        check("0.6 finds 0.6.0", WhatsNew.release(for: "0.6", in: releases)?.version == "0.6.0")
        check("no entry for 0.6.1", WhatsNew.release(for: "0.6.1", in: releases) == nil)
        check("garbage reads as nothing", WhatsNew.releases(Data("{".utf8)).isEmpty)

        print("\nLanguage")
        let title = releases[0].items[0].title
        check("fr", WhatsNew.text(title, languages: ["fr"]) == "Un")
        check("fr-CA falls back to fr", WhatsNew.text(title, languages: ["fr-CA"]) == "Un")
        check("pt-BR", WhatsNew.text(title, languages: ["pt-BR"]) == "Um")
        check("zh-Hant-TW falls back to zh-Hant", WhatsNew.text(title, languages: ["zh-Hant-TW"]) == "一")
        check("de missing: English", WhatsNew.text(title, languages: ["de"]) == "One")
        check("empty value: next language", WhatsNew.text(["fr": "", "en": "One"], languages: ["fr"]) == "One")

        print("\nIcons")
        check("every icon has a symbol", WhatsNew.symbols.count == 19)
        check("unknown icon: sparkles", WhatsNew.symbol("rocket") == "sparkles")

        print("\nYour Coucou so far")
        check("nothing used: no chips", WhatsNew.chips(WhatsNew.Stats()).isEmpty)
        let s = WhatsNew.Stats(sessions: 42, agentMinutes: 600, linesAdded: 9000, approvals: 120, words: 15000, minutesSaved: 90, notes: 3)
        let chips = WhatsNew.chips(s)
        check("six at most", chips.count == 6)
        check("agents first", chips.first == .sessions(42))
        check("notes cut when full", !chips.contains(.notes(3)))
        check("zeros left out", WhatsNew.chips(WhatsNew.Stats(words: 300)) == [.words(300)])
        check("less than a minute saved: left out", WhatsNew.chips(WhatsNew.Stats(words: 5, minutesSaved: 0)) == [.words(5)])

        print("\nThe app's own file")
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NotchBuddy/Resources/whats-new.json")
        if let data = try? Data(contentsOf: path) {
            let own = WhatsNew.releases(data)
            check("whats-new.json reads", !own.isEmpty)
            check("its icons all have a symbol", own.allSatisfy { $0.items.allSatisfy { WhatsNew.symbols[$0.icon] != nil } })
        } else {
            check("whats-new.json is there", false)
        }

        print("\nLinks")
        check("coffee goes to Stripe", WhatsNew.coffeeURL.host == "buy.stripe.com")
        check("release page", WhatsNew.releasePage("0.6.0").absoluteString == "https://github.com/Louis-CFM/coucou/releases/tag/v0.6.0")

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll What's new tests passed")
    }
}

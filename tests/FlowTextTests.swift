import Foundation

@main
enum FlowTextTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func eq(_ label: String, _ got: String, _ want: String) {
        check(label + (got == want ? "" : " — got \"\(got)\""), got == want)
    }

    static func main() {
        print("\nReplacements")
        eq("whole words, any case", FlowText.replacing("cloud code", with: "Claude Code", in: "J'ouvre Cloud Code ce soir"),
           "J'ouvre Claude Code ce soir")
        eq("never inside a word", FlowText.replacing("art", with: "ART", in: "partir à l'art"), "partir à l'ART")
        eq("any separator between the words", FlowText.replacing("rendez vous", with: "RDV", in: "un Rendez-vous demain"),
           "un RDV demain")
        eq("a $ in the replacement stays as is", FlowText.replacing("prix", with: "$5", in: "le prix"), "le $5")
        eq("an empty phrase changes nothing", FlowText.replacing("", with: "x", in: "abc"), "abc")

        print("\nSnippets, replacements, dictionary")
        let snippet = FlowSnippet(trigger: "mon lien de rendez-vous", text: "cal.com/louis/30min")
        eq("a snippet becomes its text", FlowText.apply("Mon lien de rendez vous.", words: [], replacements: [], snippets: [snippet]),
           "cal.com/louis/30min.")
        eq("the dictionary fixes the spelling", FlowText.apply("on passe sur supabase et n8n", words: ["Supabase", "n8n"],
                                                               replacements: [], snippets: []),
           "on passe sur Supabase et n8n")
        eq("a word with symbols is left alone", FlowText.apply("c'est du c ou du C++", words: ["C++"], replacements: [], snippets: []),
           "c'est du c ou du C++")
        let link = FlowSnippet(trigger: "mon lien", text: "cal.com/louis/30min")
        eq("the dictionary never touches a snippet's text",
           FlowText.apply("voici mon lien Louis", words: ["Louis"], replacements: [], snippets: [link]),
           "voici cal.com/louis/30min Louis")
        let prepared = FlowText.prepare("voici mon lien", words: [], replacements: [], snippets: [link])
        check("the trigger becomes a mark", prepared.text == "voici ⟦1⟧" && prepared.snippets["⟦1⟧"] == link.text)
        check("a rewrite that lost the mark is refused", !FlowText.keepsMarks("voici le lien", prepared.snippets))
        eq("the mark becomes the text", FlowText.finish("Voici ⟦1⟧.", snippets: prepared.snippets), "Voici cal.com/louis/30min.")
        let fix = FlowReplacement(from: "heute haine", to: "n8n")
        eq("replacement then dictionary", FlowText.apply("lance heute haine", words: ["N8N"], replacements: [fix], snippets: []),
           "lance N8N")

        print("\nNumbers")
        check("9 words", FlowText.wordCount("Salut, c'est Louis : on se voit à 15 h ?") == 9)
        check("wpm", FlowText.wordsPerMinute(words: 200, seconds: 60) == 200)
        check("wpm needs a second", FlowText.wordsPerMinute(words: 3, seconds: 0.5) == 0)
        check("saved minutes", abs(FlowText.minutesSaved(words: 450, seconds: 120) - 8) < 0.001)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 18))!
        check("day key", FlowText.dayKey(today, calendar: calendar) == "2026-10-14")
        check("streak of 3 ending today",
              FlowText.streak(days: ["2026-10-14", "2026-10-13", "2026-10-12", "2026-10-10"], today: today, calendar: calendar) == 3)
        check("streak still counts when today has none yet",
              FlowText.streak(days: ["2026-10-13", "2026-10-12"], today: today, calendar: calendar) == 2)
        check("no streak", FlowText.streak(days: ["2026-10-01"], today: today, calendar: calendar) == 0)
        let fr = Locale(identifier: "fr_FR")
        check("short count under 10 000", FlowText.shortCount(9_500, locale: Locale(identifier: "en_US")) == "9,500")
        let short = FlowText.shortCount(36_800, locale: fr)
        check("short count 36,8 k (\(short))", short == "36,8 k")

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll Flow text tests passed")
    }
}

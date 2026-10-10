import Foundation

// MARK: - IntentParser tests (uses PillFixture.available — real catalog)

@main
enum IntentParserTests {

    static var pass = 0
    static var fail = 0

    static let pills = PillFixture.available

    static func main() {

        // ── Music: pause ──────────────────────────────────────────────────────
        check("pause",                       parse("pause"),                   .musicPause)
        check("stop",                        parse("stop"),                    .musicPause)
        check("stoppe",                      parse("stoppe"),                  .musicPause)
        check("mets en pause",               parse("mets en pause"),           .musicPause)
        check("arrête la musique",           parse("arrête la musique"),       .musicPause)
        check("PAUSE",                       parse("PAUSE"),                   .musicPause)
        check("coupe la musique",            parse("coupe la musique"),        .musicPause)
        check("arrête",                      parse("arrête"),                  .musicPause)

        // ── Music: play (generic, nil target) ────────────────────────────────
        check("lance la musique",            parse("lance la musique"),        .musicPlay(target: nil))
        check("reprends",                    parse("reprends"),                .musicPlay(target: nil))
        check("reprends la musique",         parse("reprends la musique"),     .musicPlay(target: nil))
        check("play music",                  parse("play music"),              .musicPlay(target: nil))
        check("resume music",                parse("resume music"),            .musicPlay(target: nil))
        check("play some music",             parse("play some music"),         .musicPlay(target: nil))
        check("balance de la musique",       parse("balance de la musique"),   .musicPlay(target: nil))
        check("mets de la musique",          parse("mets de la musique"),      .musicPlay(target: nil))
        check("mets du son",                 parse("mets du son"),             .musicPlay(target: nil))

        // ── Music: play with target ───────────────────────────────────────────
        check("lance Apple Music",           parse("lance Apple Music", pills: pills), .musicPlay(target: .appleMusic))
        check("lance Spotify",               parse("lance Spotify", pills: pills),     .musicPlay(target: .spotify))
        check("mets de la musique sur Spotify", parse("mets de la musique sur Spotify", pills: pills), .musicPlay(target: .spotify))

        // ── Music: next/prev ──────────────────────────────────────────────────
        check("suivant",                     parse("suivant"),                 .musicNext)
        check("morceau suivant",             parse("morceau suivant"),         .musicNext)
        check("chanson suivante",            parse("chanson suivante"),        .musicNext)
        check("next",                        parse("next"),                    .musicNext)
        check("next track",                  parse("next track"),              .musicNext)
        check("skip",                        parse("skip"),                    .musicNext)
        check("next song",                   parse("next song"),               .musicNext)
        check("chanson d'après",             parse("chanson d'après"),         .musicNext)
        check("passe à la suivante",         parse("passe à la suivante"),     .musicNext)
        check("précédent",                   parse("précédent"),               .musicPrevious)
        check("morceau précédent",           parse("morceau précédent"),       .musicPrevious)
        check("previous",                    parse("previous"),                .musicPrevious)
        check("previous track",              parse("previous track"),          .musicPrevious)
        check("back",                        parse("back"),                    .musicPrevious)
        check("remets la chanson d'avant",   parse("remets la chanson d'avant"), .musicPrevious)
        check("reviens en arrière",          parse("reviens en arrière"),      .musicPrevious)

        // ── Music: volume ─────────────────────────────────────────────────────
        check("monte le son",                parse("monte le son"),            .musicVolumeUp)
        check("monte le volume",             parse("monte le volume"),         .musicVolumeUp)
        check("plus fort",                   parse("plus fort"),               .musicVolumeUp)
        check("volume up",                   parse("volume up"),               .musicVolumeUp)
        check("louder",                      parse("louder"),                  .musicVolumeUp)
        check("monte un peu le volume",      parse("monte un peu le volume"),  .musicVolumeUp)
        check("baisse le son",               parse("baisse le son"),           .musicVolumeDown)
        check("baisse le volume",            parse("baisse le volume"),        .musicVolumeDown)
        check("moins fort",                  parse("moins fort"),              .musicVolumeDown)
        check("volume down",                 parse("volume down"),             .musicVolumeDown)
        check("quieter",                     parse("quieter"),                 .musicVolumeDown)
        check("turn down",                   parse("turn down"),               .musicVolumeDown)
        check("baisse un peu le son",        parse("baisse un peu le son"),    .musicVolumeDown)

        // ── Music: volume set ─────────────────────────────────────────────────
        check("volume à 50",                 parse("volume à 50"),             .musicSetVolume(50))
        check("set volume 75",               parse("set volume 75"),           .musicSetVolume(75))
        check("volume 0",                    parse("volume 0"),                .musicSetVolume(0))
        check("volume 100",                  parse("volume 100"),              .musicSetVolume(100))

        // ── Music: search (title or artist) ───────────────────────────────────
        checkSearch("mets du Daft Punk",     parse("mets du Daft Punk",   pills: pills), "daft punk")
        checkSearch("mets de la jazz",       parse("mets de la jazz",     pills: pills), "jazz")
        checkSearch("joue du rock",          parse("joue du rock",        pills: pills), "rock")
        checkSearch("joue Daft Punk",        parse("joue Daft Punk",      pills: pills), "daft punk")
        checkSearch("play Radiohead",        parse("play Radiohead",      pills: pills), "radiohead")
        checkSearch("lance du Bowie",        parse("lance du Bowie",      pills: pills), "bowie")
        checkSearch("mets les Beatles",      parse("mets les Beatles",    pills: pills), "beatles")
        checkSearch("joue de l'électro",     parse("joue de l'électro",   pills: pills), "electro")
        checkSearch("joue Get Lucky",        parse("joue Get Lucky",      pills: pills), "get lucky")

        // ── Music: playlist ───────────────────────────────────────────────────
        checkPlaylist("mets la playlist Workout",   parse("mets la playlist Workout",  pills: pills), "workout")
        checkPlaylist("joue la playlist Jazz",      parse("joue la playlist Jazz",     pills: pills), "jazz")
        checkPlaylist("lance la playlist Summer",   parse("lance la playlist Summer",  pills: pills), "summer")
        checkPlaylist("play playlist My Favs",      parse("play playlist My Favs",     pills: pills), "my favs")
        checkPlaylist("start playlist Chill",       parse("start playlist Chill",      pills: pills), "chill")
        checkPlaylist("mets la playlist Focus",     parse("mets la playlist Focus",    pills: pills), "focus")
        checkPlaylist("mets ma playlist Focus",     parse("mets ma playlist Focus",    pills: pills), "focus")
        checkPlaylist("lance ma playlist Focus",    parse("lance ma playlist Focus",   pills: pills), "focus")

        // ── Pill: add ─────────────────────────────────────────────────────────
        check("ajoute GitHub",               parse("ajoute GitHub",        pills: pills), .pillAdd(id: "integration_github"))
        check("ajoute Vercel",               parse("ajoute Vercel",        pills: pills), .pillAdd(id: "integration_vercel"))
        check("active Notion",               parse("active Notion",        pills: pills), .pillAdd(id: "integration_notion"))
        check("add GitHub",                  parse("add GitHub",            pills: pills), .pillAdd(id: "integration_github"))
        check("enable Vercel",               parse("enable Vercel",         pills: pills), .pillAdd(id: "integration_vercel"))
        check("show Resend",                 parse("show Resend",           pills: pills), .pillAdd(id: "integration_resend"))
        check("affiche Notion",              parse("affiche Notion",        pills: pills), .pillAdd(id: "integration_notion"))
        check("ajoute gemini",               parse("ajoute gemini",         pills: pills), .pillAdd(id: "agent_gemini"))
        check("ajoute claude",               parse("ajoute claude",         pills: pills), .pillAdd(id: "integration_claude"))
        check("mets la pilule Gemini",       parse("mets la pilule Gemini", pills: pills), .pillAdd(id: "agent_gemini"))
        check("mets la pilule Codex",        parse("mets la pilule Codex",  pills: pills), .pillAdd(id: "agent_codex"))

        // ── Pill: add multiple ────────────────────────────────────────────────
        check("ajoute Vercel et Stripe",
              parse("ajoute Vercel et Stripe", pills: pills),
              .pillAddMultiple(ids: ["integration_vercel", "integration_stripe"]))

        // ── Pill: remove ──────────────────────────────────────────────────────
        check("enlève GitHub",               parse("enlève GitHub",        pills: pills), .pillRemove(id: "integration_github"))
        check("enlève Vercel",               parse("enlève Vercel",        pills: pills), .pillRemove(id: "integration_vercel"))
        check("désactive Notion",            parse("désactive Notion",     pills: pills), .pillRemove(id: "integration_notion"))
        check("cache Resend",                parse("cache Resend",          pills: pills), .pillRemove(id: "integration_resend"))
        check("remove GitHub",               parse("remove GitHub",         pills: pills), .pillRemove(id: "integration_github"))
        check("disable Vercel",              parse("disable Vercel",        pills: pills), .pillRemove(id: "integration_vercel"))
        check("hide Notion",                 parse("hide Notion",           pills: pills), .pillRemove(id: "integration_notion"))
        check("enlève stripe",               parse("enlève stripe",         pills: pills), .pillRemove(id: "integration_stripe"))

        // ── Pill: remove multiple ─────────────────────────────────────────────
        check("enlève Stripe et Notion",
              parse("enlève Stripe et Notion", pills: pills),
              .pillRemoveMultiple(ids: ["integration_stripe", "integration_notion"]))

        // ── Pill: setMain ─────────────────────────────────────────────────────
        check("passe sur Cursor",            parse("passe sur Cursor",         pills: pills), .pillSetMain(id: "agent_cursor"))
        check("switch to Cursor",            parse("switch to Cursor",         pills: pills), .pillSetMain(id: "agent_cursor"))
        check("utilise VS Code",             parse("utilise VS Code",          pills: pills), .pillSetMain(id: "integration_claude"))
        check("passe la pilule principale sur cursor",
              parse("passe la pilule principale sur cursor", pills: pills),
              .pillSetMain(id: "agent_cursor"))
        check("mets Cursor en principal",
              parse("mets Cursor en principal", pills: pills),
              .pillSetMain(id: "agent_cursor"))
        check("change la pilule principale pour Codex",
              parse("change la pilule principale pour Codex", pills: pills),
              .pillSetMain(id: "agent_codex"))
        check("la pilule principale c'est Cursor",
              parse("la pilule principale c'est Cursor", pills: pills),
              .pillSetMain(id: "agent_cursor"))
        check("Cursor comme pilule principale",
              parse("Cursor comme pilule principale", pills: pills),
              .pillSetMain(id: "agent_cursor"))

        // ── Pill: replace / only ──────────────────────────────────────────────
        check("remplace n8n par github",
              parse("remplace n8n par github", pills: pills),
              .pillReplace(old: "integration_n8n", new: "integration_github"))
        check("garde seulement GitHub et Vercel",
              parse("garde seulement GitHub et Vercel", pills: pills),
              .pillOnly(["integration_github", "integration_vercel"]))

        // ── Unknown: non-pill entities / bare trigger words ───────────────────
        check("unknown command xyz",         parse("unknown command xyz"),     .unknown)
        check("empty",                       parse(""),                        .unknown)
        check("coucou seul",                 parse("coucou"),                  .unknown)
        check("utilise ton cerveau",         parse("utilise ton cerveau", pills: pills), .unknown)
        check("show me",                     parse("show me", pills: pills),   .unknown)

        // ── Normalisation edge cases ──────────────────────────────────────────
        check("MONTE LE SON caps",           parse("MONTE LE SON"),            .musicVolumeUp)
        check("mònte lê sôn diacritics",     parse("mònte lê sôn"),            .musicVolumeUp)
        check("next trailing punct",         parse("next!"),                   .musicNext)

        // ── Politeness prefixes + infinitives ────────────────────────────────
        check("tu peux mettre de la musique",
              parse("tu peux mettre de la musique"),
              .musicPlay(target: nil))
        check("est-ce que tu peux enlever Vercel",
              parse("est-ce que tu peux enlever Vercel", pills: pills),
              .pillRemove(id: "integration_vercel"))
        check("peux-tu ajouter GitHub",
              parse("peux-tu ajouter GitHub", pills: pills),
              .pillAdd(id: "integration_github"))
        check("could you play some music",
              parse("could you play some music"),
              .musicPlay(target: nil))
        check("tu pourrais baisser le son",
              parse("tu pourrais baisser le son"),
              .musicVolumeDown)

        // ── Filler words: "truc", "chose", "machin" ──────────────────────────
        check("mets le truc Gemini",
              parse("mets le truc Gemini", pills: pills),
              .pillAdd(id: "agent_gemini"))
        check("ajoute la chose GitHub",
              parse("ajoute la chose GitHub", pills: pills),
              .pillAdd(id: "integration_github"))
        check("enlève le machin Vercel",
              parse("enlève le machin Vercel", pills: pills),
              .pillRemove(id: "integration_vercel"))
        check("mets le bidule Stripe",
              parse("mets le bidule Stripe", pills: pills),
              .pillAdd(id: "integration_stripe"))

        // ── Filler words: "pile", "aussi", "stp" ────────────────────────
        check("ajoute la pile GitHub",
              parse("ajoute la pile GitHub", pills: pills),
              .pillAdd(id: "integration_github"))
        check("ajoute aussi Stripe",
              parse("ajoute aussi Stripe", pills: pills),
              .pillAdd(id: "integration_stripe"))
        check("enlève la pile Vercel",
              parse("enlève la pile Vercel", pills: pills),
              .pillRemove(id: "integration_vercel"))

        // ── New add triggers ─────────────────────────────────────────────
        check("je veux GitHub",
              parse("je veux GitHub", pills: pills),
              .pillAdd(id: "integration_github"))
        check("il me faut Notion",
              parse("il me faut Notion", pills: pills),
              .pillAdd(id: "integration_notion"))

        // ── New remove triggers ──────────────────────────────────────────
        check("vire GitHub",
              parse("vire GitHub", pills: pills),
              .pillRemove(id: "integration_github"))
        check("dégage Vercel",
              parse("dégage Vercel", pills: pills),
              .pillRemove(id: "integration_vercel"))
        check("enlève-moi Notion",
              parse("enlève-moi Notion", pills: pills),
              .pillRemove(id: "integration_notion"))
        check("plus besoin de Stripe",
              parse("plus besoin de Stripe", pills: pills),
              .pillRemove(id: "integration_stripe"))

        // ── parseMultiAction ─────────────────────────────────────────────────
        checkMultiAction("mets le truc Gemini et enlève GitHub",
                         parseMulti("mets le truc Gemini et enlève GitHub"),
                         [.pillAdd(id: "agent_gemini"), .pillRemove(id: "integration_github")])
        checkMultiAction("ajoute Stripe puis enlève Vercel",
                         parseMulti("ajoute Stripe puis enlève Vercel"),
                         [.pillAdd(id: "integration_stripe"), .pillRemove(id: "integration_vercel")])
        checkMultiAction("add GitHub then remove Vercel",
                         parseMulti("add GitHub then remove Vercel"),
                         [.pillAdd(id: "integration_github"), .pillRemove(id: "integration_vercel")])
        // Comma splitting
        checkMultiAction("ajoute GitHub, enlève Vercel",
                         parseMulti("ajoute GitHub, enlève Vercel"),
                         [.pillAdd(id: "integration_github"), .pillRemove(id: "integration_vercel")])

        // No separator: a second action verb starts a new action
        checkMultiAction("ajoute Stripe enlève Vercel",
                         parseMulti("ajoute Stripe enlève Vercel"),
                         [.pillAdd(id: "integration_stripe"), .pillRemove(id: "integration_vercel")])
        checkMultiAction("enlève GitHub mets Notion",
                         parseMulti("enlève GitHub mets Notion"),
                         [.pillRemove(id: "integration_github"), .pillAdd(id: "integration_notion")])
        checkMultiAction("tu peux enlever GitHub et ajouter Notion",
                         parseMulti("tu peux enlever GitHub et ajouter Notion"),
                         [.pillRemove(id: "integration_github"), .pillAdd(id: "integration_notion")])
        checkMultiAction("enlève Vercel ajoute Notion et Stripe",
                         parseMulti("enlève Vercel ajoute Notion et Stripe"),
                         [.pillRemove(id: "integration_vercel"),
                          .pillAddMultiple(ids: ["integration_notion", "integration_stripe"])])
        checkMultiAction("retire Vercel, ajoute Notion",
                         parseMulti("retire Vercel, ajoute Notion"),
                         [.pillRemove(id: "integration_vercel"), .pillAdd(id: "integration_notion")])
        checkMultiAction("pause et ajoute Notion",
                         parseMulti("pause et ajoute Notion"),
                         [.musicPause, .pillAdd(id: "integration_notion")])
        checkMultiAction("lance la musique ajoute Notion",
                         parseMulti("lance la musique ajoute Notion"),
                         [.musicPlay(target: nil), .pillAdd(id: "integration_notion")])
        // A band name with "et" stays one search
        checkNilMultiAction("mets du Simon et Garfunkel",
                            parseMulti("mets du Simon et Garfunkel"))
        checkNilMultiAction("ajoute Notion et Stripe",
                            parseMulti("ajoute Notion et Stripe"))
        // Trailing location is ignored
        check("ajoute Notion dans les pilules",
              parse("ajoute Notion dans les pilules", pills: pills), .pillAdd(id: "integration_notion"))
        check("mets Notion dans le notch",
              parse("mets Notion dans le notch", pills: pills), .pillAdd(id: "integration_notion"))

        // Single pill with conjunction → NOT multi-action (fallback to single-intent)
        checkNilMultiAction("mets Gemini et Cursor",
                            parseMulti("mets Gemini et Cursor"))
        // Unknown part → not multi-action
        checkNilMultiAction("mets Gemini et blahblah",
                            parseMulti("mets Gemini et blahblah"))

        // Summary
        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }

    static func parse(_ s: String, pills: [PillDefinition] = []) -> VoiceIntent {
        IntentParser.parse(s, pills: pills)
    }

    static func parseMulti(_ s: String) -> [VoiceIntent]? {
        IntentParser.parseMultiAction(s, pills: pills)
    }

    static func checkMultiAction(_ label: String, _ got: [VoiceIntent]?, _ want: [VoiceIntent]) {
        guard let got else {
            print("✗  \(label) — got nil, want \(want)"); fail += 1; return
        }
        if got == want {
            print("✓  \(label)"); pass += 1
        } else {
            print("✗  \(label) — got \(got), want \(want)"); fail += 1
        }
    }

    static func checkNilMultiAction(_ label: String, _ got: [VoiceIntent]?) {
        if got == nil {
            print("✓  \(label) → nil (expected)"); pass += 1
        } else {
            print("✗  \(label) — expected nil, got \(got!)"); fail += 1
        }
    }

    static func check(_ label: String, _ got: VoiceIntent, _ want: VoiceIntent) {
        if got == want {
            print("✓  \(label)"); pass += 1
        } else {
            print("✗  \(label) — got \(got), want \(want)"); fail += 1
        }
    }

    static func checkSearch(_ label: String, _ got: VoiceIntent, _ want: String) {
        if case .musicPlaySearch(let name) = got,
           IntentParser.normalise(name) == want {
            print("✓  \(label)"); pass += 1
        } else {
            print("✗  \(label) — got \(got), want search '\(want)'"); fail += 1
        }
    }

    static func checkPlaylist(_ label: String, _ got: VoiceIntent, _ want: String) {
        if case .musicPlayPlaylist(let name) = got,
           IntentParser.normalise(name) == want {
            print("✓  \(label)"); pass += 1
        } else {
            print("✗  \(label) — got \(got), want playlist '\(want)'"); fail += 1
        }
    }
}

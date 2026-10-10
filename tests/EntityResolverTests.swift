import Foundation

@main
enum EntityResolverTests {

    static var pass = 0
    static var fail = 0

    static let pills = PillFixture.available

    static func main() {

        // ── Exact matches ─────────────────────────────────────────────────────
        check("GitHub exact",      resolve("GitHub"),       "integration_github")
        check("Vercel exact",      resolve("Vercel"),       "integration_vercel")
        check("Notion exact",      resolve("Notion"),       "integration_notion")
        check("Resend exact",      resolve("Resend"),       "integration_resend")
        check("Stripe exact",      resolve("Stripe"),       "integration_stripe")
        check("Anthropic exact",   resolve("Anthropic"),    "ai_anthropic")
        check("Cursor exact",      resolve("Cursor"),       "agent_cursor")
        check("n8n exact",         resolve("n8n"),          "integration_n8n")
        check("Apple Music exact", resolve("Apple Music"),  "integration_music")
        check("Spotify exact",     resolve("Spotify"),      "integration_spotify")
        check("VS Code exact",     resolve("VS Code"),      "integration_claude")
        check("OpenAI exact",      resolve("OpenAI"),       "ai_openai")
        check("LM Studio exact",   resolve("LM Studio"),    "ai_lmstudio")
        check("Google AI exact",   resolve("Google AI"),    "ai_google")

        // ── Aliases ───────────────────────────────────────────────────────────
        check("claude alias",      resolve("claude"),       "integration_claude")
        check("claude code alias", resolve("claude code"),  "integration_claude")
        check("gemini alias",      resolve("gemini"),       "agent_gemini")
        check("copilot alias",     resolve("copilot"),      "agent_copilot")
        check("google alias",      resolve("google"),       "ai_google")
        check("music alias",       resolve("music"),        "integration_music")
        check("musique alias",     resolve("musique"),      "integration_music")
        check("muse alias",        resolve("muse"),         "agent_muse")
        check("amp alias",         resolve("amp"),          "agent_amp")

        // ── Case/diacritic insensitive ────────────────────────────────────────
        check("GITHUB caps",       resolve("GITHUB"),       "integration_github")
        check("github lower",      resolve("github"),       "integration_github")
        check("vèrcel diacritic",  resolve("vèrcel"),       "integration_vercel")
        check("nótion diacritic",  resolve("nótion"),       "integration_notion")

        // ── Word-match ────────────────────────────────────────────────────────
        check("gemini word",       resolve("gemini"),       "agent_gemini")   // "gemini" in "Gemini CLI"
        check("copilot word",      resolve("copilot"),      "agent_copilot")  // "copilot" in "Copilot CLI"
        check("muse word",         resolve("muse"),         "agent_muse")     // "muse" in "Muse Code"

        // ── Levenshtein ≤ 2 ──────────────────────────────────────────────────
        check("Githb (1 del)",     resolve("Githb"),        "integration_github")
        check("Notoon (1 sub)",    resolve("Notoon"),       "integration_notion")
        check("Vecel (1 del)",     resolve("Vecel"),        "integration_vercel")
        check("Rêsend (1 sub)",    resolve("Rêsend"),       "integration_resend")

        // ── No match ─────────────────────────────────────────────────────────
        checkNil("xyz → nil",      resolve("xyz"))
        checkNil("empty → nil",    resolve(""))
        checkNil("Gitxyz far",     resolve("Gitxyz"))
        checkNil("cerveau → nil",  resolve("cerveau"))

        // ── Category filter ───────────────────────────────────────────────────
        check("Cursor workspace",      resolve("Cursor",    cat: .workspace), "agent_cursor")
        check("VS Code workspace",     resolve("VS Code",   cat: .workspace), "integration_claude")
        check("claude workspace",      resolve("claude",    cat: .workspace), "integration_claude")
        checkNil("GitHub not workspace", resolve("GitHub",  cat: .workspace))
        checkNil("gemini not workspace", resolve("gemini",  cat: .workspace))

        // ── Levenshtein distance ──────────────────────────────────────────────
        let lev = EntityResolver.levenshtein
        checkDist("abc/abc",         lev("abc",    "abc"),    0)
        checkDist("abc/abd",         lev("abc",    "abd"),    1)
        checkDist("kitten/sitting",  lev("kitten", "sitting"), 3)
        checkDist("empty/abc",       lev("",       "abc"),    3)
        checkDist("abc/empty",       lev("abc",    ""),       3)

        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }

    static func resolve(_ query: String, cat: PillCategory? = nil) -> String? {
        EntityResolver.resolve(query, from: pills, category: cat)
    }

    static func check(_ label: String, _ got: String?, _ want: String) {
        if got == want { print("✓  \(label)"); pass += 1 }
        else { print("✗  \(label) — got \(got ?? "nil"), want \(want)"); fail += 1 }
    }

    static func checkNil(_ label: String, _ got: String?) {
        if got == nil { print("✓  \(label)"); pass += 1 }
        else { print("✗  \(label) — expected nil, got \(got!)"); fail += 1 }
    }

    static func checkDist(_ label: String, _ got: Int, _ want: Int) {
        if got == want { print("✓  lev(\(label)) = \(want)"); pass += 1 }
        else { print("✗  lev(\(label)) — got \(got), want \(want)"); fail += 1 }
    }
}

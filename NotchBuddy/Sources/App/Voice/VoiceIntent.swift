#if !APPSTORE
import Foundation

// MARK: - MusicTarget

/// Where to route a play command.
enum MusicTarget: Equatable {
    case appleMusic   // force Apple Music
    case spotify      // force Spotify
}

// MARK: - VoiceIntent

/// Structured intent extracted from a voice command transcript.
/// Pure value type — no AppKit, no SwiftUI, no I/O.
enum VoiceIntent: Equatable {

    // ── Music ────────────────────────────────────────────────────────────────

    case musicPlay(target: MusicTarget?)             // nil = whichever is playing, or Apple Music
    case musicPause                                  // "pause" / "arrête"
    case musicNext                                   // "morceau suivant" / "next track"
    case musicPrevious                               // "morceau précédent" / "previous"
    case musicPlaySearch(name: String)               // "joue Get Lucky" — search track OR artist
    case musicPlayPlaylist(name: String)             // "mets la playlist Workout"
    case musicVolumeUp                               // "monte le son"
    case musicVolumeDown                             // "baisse le son"
    case musicSetVolume(Int)                         // "volume à 50"

    // ── Pills ─────────────────────────────────────────────────────────────────

    case pillAdd(id: String)                         // "ajoute GitHub"
    case pillAddMultiple(ids: [String])              // "ajoute Vercel et Stripe"
    case pillRemove(id: String)                      // "enlève Vercel"
    case pillRemoveMultiple(ids: [String])           // "enlève Stripe et Notion"
    case pillSetMain(id: String)                     // "passe sur Cursor" (workspace pills only)
    case pillReplace(old: String, new: String)       // "remplace n8n par github"
    case pillOnly([String])                          // "garde seulement GitHub et Vercel"

    // ── Questions, mail, apps ─────────────────────────────────────────────────

    case query(VoiceTopic)                           // "combien d'étoiles sur GitHub ?"
    case mail(VoiceQuery.MailRequest)                // "envoie le fichier X à Tana" (Mail opens, I click Send)
    case openApp(name: String)                       // "ouvre Figma"

    // ── Unknown ───────────────────────────────────────────────────────────────

    case unknown
}

// MARK: - VoiceActionResult

/// Outcome displayed in VoiceResultView for ~2 s after a command runs.
struct VoiceActionResult: Equatable {
    enum Outcome: Equatable {
        case success
        case failure
        /// Mochi asks a follow-up question and re-listens for 6 s.
        case question(text: String)
    }
    let outcome: Outcome
    let message: String   // e.g. "Gemini CLI ajouté" / "Pas compris"
}

// MARK: - PendingVoiceQuestion

struct PendingVoiceQuestion {
    enum Kind {
        case removeWhich(toAdd: String)   // 4-pill limit: which pill to remove to add X?
        case whichPill(add: Bool)         // "ajoute…" with no pill named: which one?
        case whichPlaylist                // "lance ma playlist": which playlist?
    }
    let kind: Kind
    let text: String
    /// True once Coucou has asked the question a second time (it never asks a third time).
    var askedAgain: Bool = false
}
#endif

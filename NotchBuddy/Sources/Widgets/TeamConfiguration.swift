import AppIntents
import WidgetKit

// The Team widget's settings: which Mochi sits in each of the four spots.
// "Automatic" fills a spot with the most urgent Mochi not already shown.

enum MochiChoice: String, AppEnum {
    case automatic
    case vscode = "integration_claude"
    case cursor = "agent_cursor"
    case codex = "agent_codex"
    case antigravity = "agent_antigravity"
    case gemini = "agent_gemini"
    case github = "integration_github"
    case stripe = "integration_stripe"
    case vercel = "integration_vercel"
    case resend = "integration_resend"
    case calcom = "integration_calcom"
    case n8n = "integration_n8n"
    case notion = "integration_notion"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mochi"

    static let caseDisplayRepresentations: [MochiChoice: DisplayRepresentation] = [
        .automatic: "Automatic",
        .vscode: "VS Code",
        .cursor: "Cursor",
        .codex: "Codex",
        .antigravity: "Antigravity",
        .gemini: "Gemini CLI",
        .github: "GitHub",
        .stripe: "Stripe",
        .vercel: "Vercel",
        .resend: "Resend",
        .calcom: "Cal.com",
        .n8n: "n8n",
        .notion: "Notion",
    ]

    /// The pill shown, nil for automatic.
    var pillId: String? { self == .automatic ? nil : rawValue }
}

struct TeamConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Team"
    static let description = IntentDescription("Pick the Mochi in each spot.")

    @Parameter(title: "Top left", default: .automatic) var spot1: MochiChoice
    @Parameter(title: "Top right", default: .automatic) var spot2: MochiChoice
    @Parameter(title: "Bottom left", default: .automatic) var spot3: MochiChoice
    @Parameter(title: "Bottom right", default: .automatic) var spot4: MochiChoice

    var picks: [String?] { [spot1.pillId, spot2.pillId, spot3.pillId, spot4.pillId] }
}

struct TeamEntry: TimelineEntry {
    let date: Date
    let sessions: [SharedSession]
    let picks: [String?]
    var tick: Int = 0
}

struct TeamProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TeamEntry {
        TeamEntry(date: .now, sessions: SharedSession.samples, picks: [nil, nil, nil, nil])
    }

    func snapshot(for configuration: TeamConfiguration, in context: Context) async -> TeamEntry {
        let saved = SharedSessions.load()
        return TeamEntry(date: .now, sessions: context.isPreview && saved.isEmpty ? SharedSession.samples : saved,
                         picks: configuration.picks)
    }

    func timeline(for configuration: TeamConfiguration, in context: Context) async -> Timeline<TeamEntry> {
        // Same as SessionsProvider: a new pose each minute for an hour.
        let sessions = SharedSessions.load()
        let start = Date.now
        let base = Int(start.timeIntervalSince1970 / 60)
        let entries = (0..<60).map { minute in
            TeamEntry(date: start.addingTimeInterval(Double(minute) * 60), sessions: sessions,
                      picks: configuration.picks, tick: base + minute)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }
}

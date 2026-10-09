import Foundation

// MARK: - Pill category

enum PillCategory: String, CaseIterable {
    case workspace
    case agent
    case ai
    case service

    var title: String {
        switch self {
        case .workspace: return String(localized: "Where you code")
        case .agent:     return String(localized: "Agents")
        case .ai:        return String(localized: "AI for the chat")
        case .service:   return String(localized: "Services")
        }
    }
}

// MARK: - Pill definition

struct PillDefinition {
    let id:         String
    let name:       String
    /// The catalog's colour for this pill, whatever the user picked.
    let defaultColor: String
    let category:   PillCategory
    /// Label shown next to the task name in the idle card header.
    let subtitle:   String
    let source:     AgentSource
    var comingSoon: Bool = false
    var githubOnly: Bool = false

    /// The colour the pill is painted with: the user's own if they picked one
    /// (Settings → Active pills), else the catalog's.
    var color: String {
        PillColors.color(for: id, catalogColor: defaultColor, in: PillColors.stored)
    }

    init(id: String, name: String, color: String, category: PillCategory, subtitle: String,
         source: AgentSource, comingSoon: Bool = false, githubOnly: Bool = false) {
        self.id = id
        self.name = name
        self.defaultColor = color
        self.category = category
        self.subtitle = subtitle
        self.source = source
        self.comingSoon = comingSoon
        self.githubOnly = githubOnly
    }

    /// Label shown in the active-session card header (workspace/agent pills only).
    var sessionSubtitle: String {
        switch id {
        case "integration_claude": return "Claude Code"
        case "agent_cursor":       return "Cursor"
        case "agent_codex":        return "Codex"
        case "agent_hermes":       return "Hermes"
        case "agent_claude-desktop": return "Claude Desktop"
        default:                   return String(localized: "Agent")
        }
    }
}

// MARK: - Catalog

enum PillCatalog {
    // All declared pills in display order.
    static let all: [PillDefinition] = [
        // ── Where you code ───────────────────────────────────────────────────
        .init(id: "integration_claude",  name: "VS Code",     color: "#F5F6F8",
              category: .workspace, subtitle: String(localized: "Integration"),  source: .claudeCode),
        .init(id: "agent_cursor",        name: "Cursor",      color: "#C0C4CC",
              category: .workspace, subtitle: String(localized: "Integration"),  source: .agent),
        .init(id: "agent_antigravity",   name: "Antigravity", color: "#E879F9",
              category: .workspace, subtitle: String(localized: "Integration"),  source: .agent,  githubOnly: true),
        .init(id: "agent_codex",         name: "Codex",       color: "#2DD4BF",
              category: .workspace, subtitle: String(localized: "Integration"),  source: .agent,  githubOnly: true),
        // ── Agents ───────────────────────────────────────────────────────────
        .init(id: "agent_gemini",        name: "Gemini CLI",  color: "#8AB4F8",
              category: .agent,     subtitle: String(localized: "Agent"),        source: .agent,  githubOnly: true),
        .init(id: "agent_copilot",       name: "Copilot CLI", color: "#818CF8",
              category: .agent,     subtitle: String(localized: "Agent"),        source: .agent,  githubOnly: true),
        .init(id: "agent_muse",          name: "Muse Code",   color: "#38BDF8",
              category: .agent,     subtitle: String(localized: "Agent"),        source: .agent,  githubOnly: true),
        .init(id: "agent_opencode",      name: "OpenCode",    color: "#4ADE80",
              category: .agent,     subtitle: String(localized: "Agent"),        source: .agent,  githubOnly: true),
        .init(id: "agent_amp",           name: "Amp",         color: "#F59E0B",
              category: .agent,     subtitle: String(localized: "Agent"),        source: .agent,  githubOnly: true),
        .init(id: "agent_hermes",        name: "Hermes",      color: "#C084FC",
              category: .agent,     subtitle: String(localized: "Agent"),        source: .agent,  githubOnly: true),
        // Claude Code sessions run from the Claude desktop app: the relay tags them
        // `coucou_agent: claude-desktop` from CLAUDE_CODE_ENTRYPOINT, so nothing to install.
        .init(id: "agent_claude-desktop", name: "Claude Desktop", color: "#D97757",
              category: .agent,     subtitle: String(localized: "Agent"),        source: .agent),
        // ── AI for the chat ──────────────────────────────────────────────────
        .init(id: "ai_anthropic",        name: "Anthropic",   color: ChatProvider.anthropic.accentHex,
              category: .ai,        subtitle: String(localized: "Chat"),         source: .n8n),
        .init(id: "ai_google",           name: "Google AI",   color: ChatProvider.google.accentHex,
              category: .ai,        subtitle: String(localized: "Chat"),         source: .n8n),
        .init(id: "ai_openai",           name: "OpenAI",      color: ChatProvider.openai.accentHex,
              category: .ai,        subtitle: String(localized: "Chat"),         source: .n8n),
        .init(id: "ai_ollama",           name: "Ollama",      color: ChatProvider.ollama.accentHex,
              category: .ai,        subtitle: String(localized: "Chat"),         source: .n8n),
        .init(id: "ai_lmstudio",         name: "LM Studio",   color: ChatProvider.lmstudio.accentHex,
              category: .ai,        subtitle: String(localized: "Chat"),         source: .n8n),
        // ── Services ─────────────────────────────────────────────────────────
        .init(id: "integration_resend",  name: "Resend",      color: "#22C55E",
              category: .service,   subtitle: String(localized: "Integration"),  source: .n8n),
        .init(id: "integration_n8n",     name: "n8n",         color: "#F29B38",
              category: .service,   subtitle: String(localized: "Integration"),  source: .n8n),
        .init(id: "integration_vercel",  name: "Vercel",      color: "#7C5CFF",
              category: .service,   subtitle: String(localized: "Integration"),  source: .n8n),
        .init(id: "integration_github",  name: "GitHub",      color: "#F4505E",
              category: .service,   subtitle: String(localized: "Integration"),  source: .n8n),
        .init(id: "integration_notion",  name: "Notion",      color: "#8C8C8C",
              category: .service,   subtitle: String(localized: "Integration"),  source: .n8n),
        .init(id: "integration_calcom",  name: "Cal.com",     color: "#C9956A",
              category: .service,   subtitle: String(localized: "Integration"),  source: .n8n),
        .init(id: "integration_stripe",  name: "Stripe",      color: "#0570DE",
              category: .service,   subtitle: String(localized: "Integration"),  source: .n8n),
        .init(id: "integration_music",   name: "Apple Music", color: "#FA2D48",
              category: .service,   subtitle: String(localized: "Integration"),  source: .n8n, githubOnly: true),
        .init(id: "integration_spotify", name: "Spotify",     color: "#1DB954",
              category: .service,   subtitle: String(localized: "Integration"),  source: .n8n, githubOnly: true),
    ]

    /// Pills available in the current build target.
    static var available: [PillDefinition] {
        #if APPSTORE
        all.filter { !$0.githubOnly }
        #else
        all
        #endif
    }

    /// Default ID for the always-on main workspace pill.
    static let defaultMainPillId = "integration_claude"

    /// Looks up a definition by task ID (nil if not in catalog).
    static func definition(for id: String) -> PillDefinition? {
        all.first { $0.id == id }
    }
}

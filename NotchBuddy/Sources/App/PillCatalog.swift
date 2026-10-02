import Foundation

// MARK: - Pill category

enum PillCategory: String, CaseIterable {
    case workspace
    case agent
    case ai
    case service

    var title: String {
        switch self {
        case .workspace: return "Where you code"
        case .agent:     return "Agents"
        case .ai:        return "AI for the chat"
        case .service:   return "Services"
        }
    }
}

// MARK: - Pill definition

struct PillDefinition {
    let id:         String
    let name:       String
    let color:      String
    let category:   PillCategory
    /// Label shown next to the task name in the idle card header.
    let subtitle:   String
    let source:     AgentSource
    var comingSoon: Bool = false
    var githubOnly: Bool = false

    /// Label shown in the active-session card header (workspace/agent pills only).
    var sessionSubtitle: String {
        switch id {
        case "integration_claude": return "Claude Code"
        case "agent_cursor":       return "Cursor"
        default:                   return "Agent"
        }
    }
}

// MARK: - Catalog

enum PillCatalog {
    // All declared pills in display order.
    static let all: [PillDefinition] = [
        // ── Where you code ───────────────────────────────────────────────────
        .init(id: "integration_claude",  name: "VS Code",     color: "#F5F6F8",
              category: .workspace, subtitle: "Integration",  source: .claudeCode),
        .init(id: "agent_cursor",        name: "Cursor",      color: "#C0C4CC",
              category: .workspace, subtitle: "Integration",  source: .agent),
        .init(id: "agent_antigravity",   name: "Antigravity", color: "#E879F9",
              category: .workspace, subtitle: "Integration",  source: .agent,  githubOnly: true),
        .init(id: "agent_codex",         name: "Codex",       color: "#2DD4BF",
              category: .workspace, subtitle: "Integration",  source: .agent,  comingSoon: true, githubOnly: true),
        // ── Agents ───────────────────────────────────────────────────────────
        .init(id: "agent_gemini",        name: "Gemini CLI",  color: "#8AB4F8",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        // ── AI for the chat ──────────────────────────────────────────────────
        .init(id: "ai_anthropic",        name: "Anthropic",   color: ChatProvider.anthropic.accentHex,
              category: .ai,        subtitle: "Chat",         source: .n8n),
        .init(id: "ai_google",           name: "Google AI",   color: ChatProvider.google.accentHex,
              category: .ai,        subtitle: "Chat",         source: .n8n),
        .init(id: "ai_openai",           name: "OpenAI",      color: ChatProvider.openai.accentHex,
              category: .ai,        subtitle: "Chat",         source: .n8n),
        // ── Services ─────────────────────────────────────────────────────────
        .init(id: "integration_resend",  name: "Resend",      color: "#22C55E",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_n8n",     name: "n8n",         color: "#F29B38",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_vercel",  name: "Vercel",      color: "#7C5CFF",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_github",  name: "GitHub",      color: "#F4505E",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_notion",  name: "Notion",      color: "#8C8C8C",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_calcom",  name: "Cal.com",     color: "#C9956A",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_stripe",  name: "Stripe",      color: "#0570DE",
              category: .service,   subtitle: "Integration",  source: .n8n),
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

// tests/PillFixture.swift
// Mirrors PillCatalog.all — update when PillCatalog.swift changes.
// Used by standalone test scripts; compiled with VoiceTestStubs.swift.
import Foundation

enum PillFixture {
    static let available: [PillDefinition] = [
        // ── Where you code ────────────────────────────────────────────────────
        .init(id: "integration_claude",   name: "VS Code",       color: "#F5F6F8", category: .workspace, subtitle: "Integration", source: .claudeCode),
        .init(id: "agent_cursor",         name: "Cursor",        color: "#C0C4CC", category: .workspace, subtitle: "Integration", source: .agent),
        .init(id: "agent_antigravity",    name: "Antigravity",   color: "#E879F9", category: .workspace, subtitle: "Integration", source: .agent),
        .init(id: "agent_codex",          name: "Codex",         color: "#2DD4BF", category: .workspace, subtitle: "Integration", source: .agent),
        // ── Agents ───────────────────────────────────────────────────────────
        .init(id: "agent_gemini",         name: "Gemini CLI",    color: "#8AB4F8", category: .agent,     subtitle: "Agent",       source: .agent),
        .init(id: "agent_copilot",        name: "Copilot CLI",   color: "#818CF8", category: .agent,     subtitle: "Agent",       source: .agent),
        .init(id: "agent_muse",           name: "Muse Code",     color: "#38BDF8", category: .agent,     subtitle: "Agent",       source: .agent),
        .init(id: "agent_opencode",       name: "OpenCode",      color: "#4ADE80", category: .agent,     subtitle: "Agent",       source: .agent),
        .init(id: "agent_amp",            name: "Amp",           color: "#F59E0B", category: .agent,     subtitle: "Agent",       source: .agent),
        .init(id: "agent_hermes",         name: "Hermes",        color: "#C084FC", category: .agent,     subtitle: "Agent",       source: .agent),
        .init(id: "agent_claude-desktop", name: "Claude Desktop",color: "#D97757", category: .agent,     subtitle: "Agent",       source: .agent),
        // ── AI for the chat ───────────────────────────────────────────────────
        .init(id: "ai_anthropic",         name: "Anthropic",     color: "#E07950", category: .ai,        subtitle: "Chat",        source: .n8n),
        .init(id: "ai_google",            name: "Google AI",     color: "#4285F4", category: .ai,        subtitle: "Chat",        source: .n8n),
        .init(id: "ai_openai",            name: "OpenAI",        color: "#10A37F", category: .ai,        subtitle: "Chat",        source: .n8n),
        .init(id: "ai_ollama",            name: "Ollama",        color: "#AAAAAA", category: .ai,        subtitle: "Chat",        source: .n8n),
        .init(id: "ai_lmstudio",          name: "LM Studio",     color: "#800080", category: .ai,        subtitle: "Chat",        source: .n8n),
        // ── Services ──────────────────────────────────────────────────────────
        .init(id: "integration_resend",   name: "Resend",        color: "#22C55E", category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_n8n",      name: "n8n",           color: "#F29B38", category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_vercel",   name: "Vercel",        color: "#7C5CFF", category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_github",   name: "GitHub",        color: "#F4505E", category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_notion",   name: "Notion",        color: "#8C8C8C", category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_calcom",   name: "Cal.com",       color: "#C9956A", category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_stripe",   name: "Stripe",        color: "#0570DE", category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_music",    name: "Apple Music",   color: "#FA2D48", category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_spotify",  name: "Spotify",       color: "#1DB954", category: .service,   subtitle: "Integration", source: .n8n),
    ]
}

package com.coucou.android.core

/**
 * Pill catalog, a mirror of windows/src/core/pills.ts (itself PillCatalog.swift).
 * IDs, names, colours and categories are contract values and never change once shipped.
 * Apple Music is left out: it has no Android equivalent (support "no" on the desktop ports).
 */
enum class PillCategory { WORKSPACE, AGENT, AI, SERVICE }

data class PillDefinition(
    val id: String,
    val name: String,
    val colorHex: String,
    val category: PillCategory,
)

object Pills {
    const val DEFAULT_MAIN_PILL = "integration_claude"

    val catalog: List<PillDefinition> = listOf(
        PillDefinition("integration_claude", "VS Code", "#F5F6F8", PillCategory.WORKSPACE),
        PillDefinition("agent_cursor", "Cursor", "#C0C4CC", PillCategory.WORKSPACE),
        PillDefinition("agent_antigravity", "Antigravity", "#E879F9", PillCategory.WORKSPACE),
        PillDefinition("agent_codex", "Codex", "#2DD4BF", PillCategory.WORKSPACE),
        PillDefinition("agent_gemini", "Gemini CLI", "#8AB4F8", PillCategory.AGENT),
        PillDefinition("agent_copilot", "Copilot CLI", "#818CF8", PillCategory.AGENT),
        PillDefinition("agent_muse", "Muse Code", "#38BDF8", PillCategory.AGENT),
        PillDefinition("agent_opencode", "OpenCode", "#4ADE80", PillCategory.AGENT),
        PillDefinition("agent_amp", "Amp", "#F59E0B", PillCategory.AGENT),
        PillDefinition("agent_hermes", "Hermes", "#C084FC", PillCategory.AGENT),
        PillDefinition("agent_claude-desktop", "Claude Desktop", "#D97757", PillCategory.AGENT),
        PillDefinition("ai_anthropic", "Anthropic", "#E07950", PillCategory.AI),
        PillDefinition("ai_google", "Google AI", "#4285F4", PillCategory.AI),
        PillDefinition("ai_openai", "OpenAI", "#10A37F", PillCategory.AI),
        PillDefinition("ai_ollama", "Ollama", "#FACC15", PillCategory.AI),
        PillDefinition("ai_lmstudio", "LM Studio", "#A3E635", PillCategory.AI),
        PillDefinition("integration_resend", "Resend", "#22C55E", PillCategory.SERVICE),
        PillDefinition("integration_n8n", "n8n", "#F29B38", PillCategory.SERVICE),
        PillDefinition("integration_vercel", "Vercel", "#7C5CFF", PillCategory.SERVICE),
        PillDefinition("integration_github", "GitHub", "#F4505E", PillCategory.SERVICE),
        PillDefinition("integration_notion", "Notion", "#8C8C8C", PillCategory.SERVICE),
        PillDefinition("integration_calcom", "Cal.com", "#C9956A", PillCategory.SERVICE),
        PillDefinition("integration_stripe", "Stripe", "#0570DE", PillCategory.SERVICE),
        PillDefinition("integration_spotify", "Spotify", "#1DB954", PillCategory.SERVICE),
    )

    fun byId(id: String): PillDefinition? = catalog.firstOrNull { it.id == id }
}

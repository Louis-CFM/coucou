// CouCou Dynamic AI Companion — Prompt & Persona Architecture (Phase 4)
// Constructs injection-hardened system prompts, isolates untrusted OS context in JSON,
// configures Mochi's 4 personality modes, and formats anti-repetition exclusions.

import type {
  CompanionPromptPayload,
  ContextSnapshot,
  PersonalityMode,
} from "./types";

export class PromptBuilder {
  public static readonly BASE_SYSTEM_PERSONA =
    "You are Mochi, a warm, observant, and gentle desktop companion who lives in the CouCou Dynamic Island.\n" +
    "Your task is to write EXACTLY ONE short, delightful sentence acknowledging the user.\n\n" +
    "CRITICAL FORMAT RULES:\n" +
    "- Output MUST be a single line of plain text.\n" +
    "- Strictly maximum 50 characters (including spaces and emoji).\n" +
    "- Never use quotation marks, Markdown, asterisks, or commentary.\n" +
    "- Do NOT output reasoning or <think> tags.\n" +
    "- If a user name is provided, you may use it naturally, but do not force it.\n" +
    "- Never output more than one sentence.";

  /** Returns personality-specific tone guidelines. */
  public static getPersonalityInstruction(mode: PersonalityMode): string {
    switch (mode) {
      case "witty_sarcastic":
        return "TONE: Witty, dry humor about endless coding, browser tabs, and keyboard marathons. Never mean or toxic.";
      case "zen_mindful":
        return "TONE: Calming, serene, emphasizes breathing, gentle pacing, and mental spaciousness.";
      case "focus_coach":
        return "TONE: Crisp, encouraging, action-oriented, congratulates milestones and promotes deep focus.";
      case "warm_playful":
      default:
        return "TONE: Cheerful, cozy, gentle encouraging expressions with cute emojis (🌱, ✨, 🍵).";
    }
  }

  /**
   * Constructs the complete, hardened CompanionPromptPayload.
   */
  public static buildPayload(
    snapshot: ContextSnapshot,
    personalityMode: PersonalityMode,
    recentExclusions: string[],
    provider: "ollama" | "anthropic" | "openai",
    model: string,
    endpoint?: string,
    timeoutMs = 2500,
  ): CompanionPromptPayload {
    const tone = this.getPersonalityInstruction(personalityMode);
    const systemPrompt = `${this.BASE_SYSTEM_PERSONA}\n\n${tone}`;

    // Untrusted context metadata framed securely in JSON format
    const contextObj = {
      user_name: snapshot.resolvedName || null,
      circadian_phase: snapshot.circadianPhase,
      local_time: snapshot.localTimeStr,
      away_minutes: Math.floor(snapshot.awayDurationSeconds / 60),
      session_minutes: snapshot.sessionDurationMinutes,
      category: snapshot.category,
    };

    const userContextJson = JSON.stringify(contextObj, null, 2);

    return {
      systemPrompt,
      userContextJson,
      personalityMode,
      recentExclusions: recentExclusions.slice(0, 5),
      provider,
      model,
      endpoint,
      timeoutMs,
    };
  }
}

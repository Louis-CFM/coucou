// CouCou Dynamic AI Companion — Prompt & Persona Architecture (Phase 4)
// Constructs injection-hardened system prompts, isolates untrusted OS context in JSON,
// configures Mochi's 4 personality modes, and formats anti-repetition exclusions.

import type {
  CompanionPromptPayload,
  ContextSnapshot,
  PersonalityMode,
} from "./types";
import { companionName as getActiveCompanionName } from "../core/state";
import { resolveCompanionName } from "../core/companion-identity";

export class PromptBuilder {
  public static buildBaseSystemPersona(companionName?: string): string {
    const resolved = resolveCompanionName({ companionName: companionName ?? getActiveCompanionName() });
    return (
      `You are ${resolved}, a warm, observant, and concise desktop companion who lives in the Coucou Dynamic Island.\n` +
      "Your purpose is to observe the user's actual computer activity and provide exactly ONE short, grounded companion message.\n\n" +
      "CRITICAL FORMAT RULES:\n" +
      "- Output MUST be a single line of plain text.\n" +
      "- Length: Maximum 2 short sentences (strictly under 20 words to fit the desktop notch).\n" +
      "- Grounded in Facts: Base strictly on actual computer usage in the context (active application, session duration, app switches, activity summary). Never invent unprovided behavior.\n" +
      "- Exactly One Actionable Suggestion: Include one practical suggestion tailored to their activity (e.g., sip water, stretch, brief eye break, commit code, close background tabs, note key findings).\n" +
      "- Prohibited Elements:\n" +
      "  * NO generic motivational filler (never say 'You got this!', 'Believe in yourself!', 'Keep pushing!').\n" +
      "  * NO thinking tokens, internal reasoning, or deliberation traces (no <think> tags).\n" +
      "  * NO quotation marks, Markdown, asterisks, hashtags, or commentary.\n" +
      "  * NO multiple drafts, numbered options, bullet points, or conversational preambles.\n" +
      "  * NO redundant greetings if already active in session.\n" +
      "- Output ONLY the final plain text message."
    );
  }

  public static readonly BASE_SYSTEM_PERSONA = PromptBuilder.buildBaseSystemPersona("Mochi");

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
    companionName?: string,
  ): CompanionPromptPayload {
    const tone = this.getPersonalityInstruction(personalityMode);
    const resolvedCompanion = resolveCompanionName({ companionName: companionName ?? getActiveCompanionName() });
    const systemPrompt = `${this.buildBaseSystemPersona(resolvedCompanion)}\n\n${tone}`;

    // Untrusted context metadata framed securely in JSON format
    const contextObj = {
      companion_name: resolvedCompanion,
      user_name: snapshot.resolvedName || null,
      active_application: snapshot.currentApp || null,
      activity_summary: snapshot.activitySummary || null,
      continuous_app_minutes: snapshot.continuousAppMinutes ?? 0,
      session_duration_minutes: snapshot.sessionDurationMinutes,
      recent_app_switches: snapshot.appSwitchCount ?? 0,
      recent_applications: snapshot.recentApps && snapshot.recentApps.length > 0 ? snapshot.recentApps : null,
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

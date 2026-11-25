// CouCou Dynamic AI Companion — Message Policy & Decision Engine (Phase 2)
// Evaluates schedule rules, quiet hours, cooldowns, and performs the authoritative
// 7-point candidate validity check upon user return.

import type {
  CompanionCategory,
  CompanionSettings,
  ContextSnapshot,
  SpeculativeCandidate,
} from "./types";

export class MessagePolicyEngine {
  public static readonly RETURN_COOLDOWN_MS = 2.5 * 60 * 1000; // 2.5 minutes
  public static readonly HYDRATION_COOLDOWN_MS = 45 * 60 * 1000; // 45 minutes
  public static readonly POSTURE_COOLDOWN_MS = 60 * 60 * 1000; // 60 minutes
  public static readonly SPECULATIVE_TTL_MS = 10 * 60 * 1000; // 10 minutes max candidate age

  private static lastReturnGreetingTime = 0;
  private static lastHydrationNudgeTime: number = (() => {
    try {
      if (typeof localStorage !== "undefined") {
        const saved = localStorage.getItem("coucou_last_water_time");
        if (saved) {
          const n = Number(saved);
          if (!isNaN(n) && n > 0) return n;
        }
      }
    } catch {}
    return Date.now();
  })();
  private static lastPostureNudgeTime = Date.now();

  /** Checks if the current local time falls within configured quiet hours. */
  public static isQuietHours(
    localTimeStr: string,
    enabled: boolean,
    startStr = "22:00",
    endStr = "08:00",
  ): boolean {
    if (!enabled) return false;

    const toMinutes = (s: string) => {
      const [h, m] = s.split(":").map(Number);
      return (h || 0) * 60 + (m || 0);
    };

    const current = toMinutes(localTimeStr);
    const start = toMinutes(startStr);
    const end = toMinutes(endStr);

    if (start > end) {
      // Overnight range, e.g. 22:00 to 08:00
      return current >= start || current < end;
    } else {
      // Same-day range, e.g. 13:00 to 14:00
      return current >= start && current < end;
    }
  }

  /** Checks whether a return greeting is permitted based on return cooldown. */
  public static canTriggerReturnGreeting(nowMs: number = Date.now()): boolean {
    return nowMs - this.lastReturnGreetingTime >= this.RETURN_COOLDOWN_MS;
  }

  /**
   * Selects the most appropriate companion category based on the context snapshot.
   */
  public static determineCategory(snapshot: ContextSnapshot): CompanionCategory {
    // Priority 1: Deep night care
    if (snapshot.circadianPhase === "deep_night") {
      return "late_night_care";
    }

    // Priority 2: User returning from an absence
    if (snapshot.awayDurationSeconds >= 120) {
      return "greeting_return";
    }

    // Priority 3: Long session deep work praise
    if (snapshot.sessionDurationMinutes >= 180) {
      return "deep_work_praise";
    }

    // Priority 4: Health nudges
    if (
      snapshot.minutesSinceHydration >= 50 &&
      Date.now() - this.lastHydrationNudgeTime >= this.HYDRATION_COOLDOWN_MS
    ) {
      return "hydration_reminder";
    }

    if (
      snapshot.sessionDurationMinutes >= 120 &&
      Date.now() - this.lastPostureNudgeTime >= this.POSTURE_COOLDOWN_MS
    ) {
      return "posture_break";
    }

    return "greeting_return";
  }

  /**
   * Determines if speculative pre-generation is permitted when user steps away.
   */
  public static isSpeculativeAllowed(
    settings: CompanionSettings,
    snapshot: ContextSnapshot,
  ): boolean {
    if (!settings.enabled) return false;
    if (settings.routingMode === "classic") return false;
    if (this.isQuietHours(snapshot.localTimeStr, settings.quietHoursEnabled, settings.quietHoursStart, settings.quietHoursEnd)) {
      return false;
    }
    return true;
  }

  /**
   * Authoritative 7-point candidate validity evaluation on user return.
   */
  public static validateCandidate(
    candidate: SpeculativeCandidate | null,
    currentSnapshot: ContextSnapshot,
    settings: CompanionSettings,
    nowMs: number = Date.now(),
  ): { valid: boolean; reason?: string } {
    // Guard 1: Is candidate present?
    if (!candidate || !candidate.text || candidate.text.trim().length === 0) {
      return { valid: false, reason: "CANDIDATE_EMPTY" };
    }

    // Guard 2: Candidate TTL check (< 600s)
    if (nowMs - candidate.generatedAt > candidate.ttlMilliseconds) {
      return { valid: false, reason: "TTL_EXPIRED" };
    }

    // Guard 3: Identity version check (user name unchanged)
    if (candidate.identityVersion !== currentSnapshot.identityVersion) {
      return { valid: false, reason: "IDENTITY_CHANGED" };
    }

    // Guard 4: Circadian phase check (clock hasn't shifted into new phase)
    if (candidate.circadianPhase !== currentSnapshot.circadianPhase) {
      return { valid: false, reason: "CIRCADIAN_TRANSITION" };
    }

    // Guard 5: Away duration deviation check (e.g. away for hours vs quick break)
    if (currentSnapshot.awayDurationSeconds > candidate.expectedDurationMaxSeconds) {
      return { valid: false, reason: "DURATION_DEVIATION" };
    }

    // Guard 6: Companion and AI feature active?
    if (!settings.enabled || settings.routingMode === "classic") {
      return { valid: false, reason: "FEATURE_DISABLED" };
    }

    // Guard 7: Return cooldown check
    if (!this.canTriggerReturnGreeting(nowMs)) {
      return { valid: false, reason: "COOLDOWN_ACTIVE" };
    }

    return { valid: true };
  }

  /** Records successful delivery of a companion message. */
  public static recordDelivered(category: CompanionCategory, nowMs: number = Date.now()): void {
    if (category === "greeting_return") {
      this.lastReturnGreetingTime = nowMs;
    } else if (category === "hydration_reminder") {
      this.lastHydrationNudgeTime = nowMs;
      try {
        if (typeof localStorage !== "undefined") {
          localStorage.setItem("coucou_last_water_time", String(nowMs));
        }
      } catch {}
    } else if (category === "posture_break") {
      this.lastPostureNudgeTime = nowMs;
    }
  }

  /** Authoritatively updates the last hydration delivery timestamp. */
  public static setLastHydrationTime(nowMs: number): void {
    this.lastHydrationNudgeTime = nowMs;
  }

  /** Resets all internal cooldown timers (for testing). */
  public static resetTimers(): void {
    this.lastReturnGreetingTime = 0;
    this.lastHydrationNudgeTime = 0;
    this.lastPostureNudgeTime = 0;
  }
}

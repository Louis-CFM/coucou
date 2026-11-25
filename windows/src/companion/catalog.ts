// CouCou Dynamic AI Companion — Deterministic Catalog Fallback (Phase 2)
// Wraps the native deterministic catalog into an infallible, zero-latency provider (<1ms).
// Serves as the guaranteed fallback whenever AI models are offline, slow, or disabled.

import type { CompanionCategory, ContextSnapshot, SpeculativeCandidate } from "./types";
import { GlobalWelcomeMessages, type WelcomeStateVector } from "../core/welcome";

export class DeterministicCatalog {
  /**
   * Resolves an instant, guaranteed-valid fallback message from the static catalog.
   * Execution latency: < 1ms.
   */
  public static resolveFallback(
    snapshot: ContextSnapshot,
    overrideCategory?: CompanionCategory,
  ): SpeculativeCandidate {
    const category = overrideCategory || snapshot.category;
    
    // Map ContextSnapshot to legacy WelcomeStateVector for catalog evaluation
    const stateVector: WelcomeStateVector = {
      awayMinutes: Math.floor(snapshot.awayDurationSeconds / 60),
      timeOfDay: snapshot.circadianPhase,
      hour: parseInt(snapshot.localTimeStr.split(":")[0] || "12", 10),
      dayOfWeek: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"].indexOf(snapshot.dayOfWeek),
      sessionWorkHours: snapshot.sessionDurationMinutes / 60,
      minutesSinceWater: snapshot.minutesSinceHydration,
      userName: snapshot.resolvedName,
      wardrobe: snapshot.mochiWardrobe,
    };

    const bestItem = GlobalWelcomeMessages.selectBestMessage(stateVector, category);
    const text = bestItem.template(snapshot.resolvedName);

    return {
      id: `static_${bestItem.id}_${Date.now()}`,
      text,
      category,
      provider: "static",
      model: "deterministic-catalog-v1",
      contextVersion: snapshot.version,
      identityVersion: snapshot.identityVersion,
      circadianPhase: snapshot.circadianPhase,
      generatedAt: Date.now(),
      ttlMilliseconds: 86400000, // 24 hours (static messages do not expire quickly)
      expectedDurationMaxSeconds: 3600,
    };
  }
}

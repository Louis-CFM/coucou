// CouCou Dynamic AI Companion — Single-Candidate Speculative Engine (Phase 5)
// Asynchronously pre-fetches a single provisional candidate while the user is away,
// buffers it in-memory with a 10-minute TTL, and reconciles freshness upon user return.

import type {
  CompanionSettings,
  ContextSnapshot,
  PrivacyConsentRecord,
  SpeculativeCandidate,
} from "./types";
import { MessagePolicyEngine } from "./policy";
import { CompanionOrchestrator } from "./orchestrator";

export class SpeculativeEngine {
  private static candidate: SpeculativeCandidate | null = null;
  private static isGenerating = false;
  private static activeSnapshotVersion = 0;

  /** Checks if a candidate is currently held in the speculative slot. */
  public static get hasCandidate(): boolean {
    return this.candidate !== null;
  }

  /** Checks if background generation is currently active. */
  public static get isBusy(): boolean {
    return this.isGenerating;
  }

  /** Gets the active candidate metadata without consuming it. */
  public static peekCandidate(): SpeculativeCandidate | null {
    return this.candidate;
  }

  /**
   * Invalidates and clears the speculative candidate slot, aborting any active generation.
   */
  public static async invalidate(): Promise<void> {
    this.candidate = null;
    this.isGenerating = false;
    this.activeSnapshotVersion = 0;
    await CompanionOrchestrator.cancelActiveRequest();
  }

  /**
   * Sets a candidate directly into the speculative slot (for testing or pipeline handoff).
   */
  public static setCandidate(candidate: SpeculativeCandidate | null): void {
    this.candidate = candidate;
  }

  /**
   * Asynchronously initiates speculative pre-generation in the background upon away detection.
   */
  public static async onUserAway(
    awaySnapshot: ContextSnapshot,
    settings: CompanionSettings,
    consent: PrivacyConsentRecord,
    recentExclusions: string[] = [],
    localEndpoint?: string,
    localModel?: string,
  ): Promise<boolean> {
    if (!MessagePolicyEngine.isSpeculativeAllowed(settings, awaySnapshot)) {
      await this.invalidate();
      return false;
    }

    // Invalidate previous candidate and mark generating
    this.candidate = null;
    this.isGenerating = true;
    this.activeSnapshotVersion = awaySnapshot.version;

    try {
      const raw = await CompanionOrchestrator.generate(
        awaySnapshot,
        settings,
        consent,
        recentExclusions,
        localEndpoint,
        localModel,
      );

      // Verify that this generation task is still active and was not invalidated or superseded
      if (!this.isGenerating || this.activeSnapshotVersion !== awaySnapshot.version) {
        return false;
      }
      this.isGenerating = false;

      if (!raw || !raw.text || raw.text.trim().length === 0) {
        return false;
      }

      this.candidate = {
        id: raw.requestId,
        text: raw.text,
        category: "greeting_return",
        provider: raw.provider as any,
        model: raw.model,
        contextVersion: awaySnapshot.version,
        identityVersion: awaySnapshot.identityVersion,
        circadianPhase: awaySnapshot.circadianPhase,
        generatedAt: Date.now(),
        ttlMilliseconds: MessagePolicyEngine.SPECULATIVE_TTL_MS,
        expectedDurationMaxSeconds: 3600, // 1 hour duration bracket
      };

      return true;
    } catch {
      this.isGenerating = false;
      this.candidate = null;
      return false;
    }
  }

  /**
   * Evaluates and consumes the candidate upon user return.
   * Returns the candidate if 7-point validity passes; otherwise returns null.
   */
  public static consumeIfValid(
    returnSnapshot: ContextSnapshot,
    settings: CompanionSettings,
    nowMs: number = Date.now(),
  ): { candidate: SpeculativeCandidate | null; reason?: string } {
    // If generation is still in-flight when user returns, abort and invalidate it
    if (this.isGenerating) {
      void this.invalidate();
    }

    const candidate = this.candidate;
    this.candidate = null; // Always clear after return event to prevent reuse

    const check = MessagePolicyEngine.validateCandidate(
      candidate,
      returnSnapshot,
      settings,
      nowMs,
    );

    if (check.valid && candidate) {
      return { candidate };
    } else {
      return { candidate: null, reason: check.reason };
    }
  }
}

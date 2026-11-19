// CouCou Dynamic AI Companion — Central AI Orchestrator (Phase 4)
// Coordinates provider selection, prompt compilation, cancellation tokens,
// timeout management, and loopback/cloud IPC execution.

import type {
  CompanionPromptPayload,
  CompanionRawCandidate,
  CompanionSettings,
  ContextSnapshot,
  PrivacyConsentRecord,
  ProviderHealthStatus,
} from "./types";
import { Bridge } from "../core/bridge";
import { PromptBuilder } from "./prompt";

export class CompanionOrchestrator {
  private static activeRequestId: string | null = null;
  private static healthCache = new Map<string, ProviderHealthStatus>();

  /** Current in-flight request ID, if any. */
  public static get currentRequestId(): string | null {
    return this.activeRequestId;
  }

  /**
   * Probes provider health and updates local health cache.
   */
  public static async probeHealth(
    provider: "ollama" | "anthropic" | "openai",
    endpoint?: string,
  ): Promise<ProviderHealthStatus | null> {
    try {
      const res = await Bridge.companionProbeHealth(provider, endpoint);
      if (res) {
        this.healthCache.set(provider, res);
      }
      return res;
    } catch {
      return null;
    }
  }

  /**
   * Cancels any active in-flight AI generation request in Rust.
   */
  public static async cancelActiveRequest(): Promise<boolean> {
    if (!this.activeRequestId) return false;
    const reqId = this.activeRequestId;
    this.activeRequestId = null;
    try {
      const cancelled = await Bridge.companionAiCancel(reqId);
      return cancelled ?? true;
    } catch {
      return false;
    }
  }

  /**
   * Generates a companion candidate according to user routing policy and privacy consent.
   */
  public static async generate(
    snapshot: ContextSnapshot,
    settings: CompanionSettings,
    consent: PrivacyConsentRecord,
    recentExclusions: string[] = [],
    localEndpoint = "http://127.0.0.1:11434",
    localModel = "qwen3.5:4b",
    cloudProvider: "anthropic" | "openai" = "anthropic",
    cloudModel = "claude-3-5-haiku-20241022",
  ): Promise<CompanionRawCandidate | null> {
    // Mode D: Classic mode bypasses AI completely
    if (!settings.enabled || settings.routingMode === "classic") {
      return null;
    }

    // Migrate legacy default model if encountered
    const effectiveLocalModel = localModel === "llama3.2" ? "qwen3.5:4b" : localModel;

    // Cancel any previous in-flight generation task before starting a new one
    await this.cancelActiveRequest();

    const requestId = `req_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
    this.activeRequestId = requestId;

    let targetProvider: "ollama" | "anthropic" | "openai" = "ollama";
    let targetModel = effectiveLocalModel;
    let endpoint: string | undefined = localEndpoint;

    if (settings.routingMode === "local_only") {
      targetProvider = "ollama";
      targetModel = effectiveLocalModel;
      endpoint = localEndpoint;
    } else if (settings.routingMode === "cloud_only") {
      if (!consent.consentedProviders[cloudProvider] || consent.consentRevoked) {
        this.activeRequestId = null;
        return null; // Cloud consent denied
      }
      targetProvider = cloudProvider;
      targetModel = cloudModel;
      endpoint = undefined;
    } else if (settings.routingMode === "auto") {
      // Check Ollama health status
      let ollamaHealth = this.healthCache.get("ollama");
      if (!ollamaHealth) {
        // Fast non-blocking probe on first demand if not already cached
        try {
          const probePromise = this.probeHealth("ollama", localEndpoint);
          const timeoutPromise = new Promise<null>((r) => setTimeout(() => r(null), 500));
          const res = await Promise.race([probePromise, timeoutPromise]);
          ollamaHealth = res ?? this.healthCache.get("ollama");
        } catch {}
      }
      const isOllamaOffline = ollamaHealth?.state === "OFFLINE";

      if (isOllamaOffline && consent.consentedProviders[cloudProvider] && !consent.consentRevoked) {
        targetProvider = cloudProvider;
        targetModel = cloudModel;
        endpoint = undefined;
      } else {
        targetProvider = "ollama";
        targetModel = effectiveLocalModel;
        endpoint = localEndpoint;
      }
    }

    const payload: CompanionPromptPayload = PromptBuilder.buildPayload(
      snapshot,
      settings.personality,
      recentExclusions,
      targetProvider,
      targetModel,
      endpoint,
      3500, // 3500ms timeout
    );

    try {
      const candidate = await Bridge.companionAiGenerate(
        requestId,
        snapshot.version,
        payload,
      );

      // Verify request wasn't superseded while awaiting IPC response
      if (this.activeRequestId !== requestId) {
        return null;
      }

      this.activeRequestId = null;
      return candidate;
    } catch (err) {
      if (this.activeRequestId === requestId) {
        this.activeRequestId = null;
      }
      return null;
    }
  }
}

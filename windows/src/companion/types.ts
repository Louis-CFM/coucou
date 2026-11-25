// CouCou Dynamic AI Companion — Core Type Contracts (Phase 0)
// Defines authoritative data models, context snapshots, provider payloads,
// candidate records, and IPC contracts for the Mochi AI Companion platform.

export type CircadianPhase =
  | "morning"
  | "afternoon"
  | "evening"
  | "night"
  | "deep_night"
  | "dawn"
  | "morning_peak"
  | "midday_lunch"
  | "afternoon_slump"
  | "golden_hour"
  | "evening_wrapup";

export type CompanionCategory =
  | "greeting_return"
  | "hydration_reminder"
  | "posture_break"
  | "deep_work_praise"
  | "late_night_care";

export type PersonalityMode =
  | "warm_playful"
  | "witty_sarcastic"
  | "zen_mindful"
  | "focus_coach";

export type RoutingMode =
  | "auto"
  | "local_only"
  | "cloud_only"
  | "classic";

export type ProviderHealthState =
  | "HEALTHY"
  | "DEGRADED"
  | "OFFLINE";

/** Immutable, versioned context state snapshot enriched with actual computer usage activity. */
export interface ContextSnapshot {
  readonly version: number;             // Monotonic sequence ID
  readonly timestamp: number;           // Unix epoch milliseconds
  readonly awayDurationSeconds: number; // Elapsed away duration
  readonly circadianPhase: CircadianPhase;
  readonly localTimeStr: string;         // "HH:MM"
  readonly dayOfWeek: string;            // "Monday" ... "Sunday"
  readonly sessionDurationMinutes: number;
  readonly minutesSinceHydration: number;
  readonly resolvedName: string;         // Authoritative greeting name or ""
  readonly identityVersion: string;      // Hash/fingerprint of active identity
  readonly mochiWardrobe: string;        // Active wardrobe outfit ID
  readonly category: CompanionCategory;
  // Actual computer activity context
  readonly currentApp: string | null;
  readonly appSwitchCount: number;
  readonly continuousAppMinutes: number;
  readonly recentApps: string[];
  readonly activitySummary: string;
}

/** Single speculative candidate held in-memory for upcoming user return. */
export interface SpeculativeCandidate {
  readonly id: string;
  readonly text: string;
  readonly category: CompanionCategory;
  readonly provider: "ollama" | "anthropic" | "openai" | "static";
  readonly model: string;
  readonly contextVersion: number;
  readonly identityVersion: string;
  readonly circadianPhase: CircadianPhase;
  readonly generatedAt: number;
  readonly ttlMilliseconds: number;      // Default 600,000ms (10 minutes)
  readonly expectedDurationMaxSeconds: number;
}

/** Raw LLM response before frontend sanitization and validation. */
export interface CompanionRawCandidate {
  readonly requestId: string;
  readonly text: string;
  readonly provider: string;
  readonly model: string;
  readonly durationMs: number;
  readonly loadDurationMs?: number;
  readonly promptEvalDurationMs?: number;
  readonly evalDurationMs?: number;
  readonly evalCount?: number;
  readonly thinkingDisabled?: boolean;
}

/** Payload passed from TypeScript orchestrator to Rust native client. */
export interface CompanionPromptPayload {
  readonly systemPrompt: string;
  readonly userContextJson: string;
  readonly personalityMode: PersonalityMode;
  readonly recentExclusions: string[];
  readonly provider: "ollama" | "anthropic" | "openai";
  readonly model: string;
  readonly endpoint?: string;
  readonly timeoutMs: number;
}

/** Provider health status record. */
export interface ProviderHealthStatus {
  readonly provider: string;
  readonly state: ProviderHealthState;
  readonly lastChecked: number;
  readonly latencyMs?: number;
  readonly error?: string;
}

/** Privacy-preserving diary entry stored in in-memory ring buffer & localStorage. */
export interface DiaryEntry {
  readonly id: string;
  readonly textFingerprint: number;      // 32-bit FNV-1a integer
  readonly significantTokens: string[];  // Normalized stems for Jaccard similarity check
  readonly category: string;
  readonly provider: string;
  readonly deliveredAt: number;          // Unix epoch milliseconds
}

/** Granular cloud privacy consent record. */
export interface PrivacyConsentRecord {
  readonly version: number;              // Current schema version: 2
  readonly consentedProviders: {
    readonly anthropic: boolean;
    readonly openai: boolean;
  };
  readonly consentedCategories: {
    readonly userGreetingName: boolean;
    readonly sessionMetrics: boolean;
  };
  readonly grantedAtTimestamp: number | null;
  readonly consentRevoked: boolean;
}

/** Authoritative Windows User Identity contract. */
export interface UserIdentityDto {
  readonly windowsDisplayName?: string | null;
  readonly windowsAccountName?: string | null;
  readonly detectedGreetingName?: string | null;
  readonly deviceName?: string | null;
  readonly isResolved: boolean;
  readonly authoritativeGreetingName?: string;
  readonly identityVersion?: string;
  readonly isCustomPreferred?: boolean;
}

/** Configuration schema v2 subset for Companion & Care. */
export interface CompanionSettings {
  readonly enabled: boolean;
  readonly routingMode: RoutingMode;
  readonly preferredName: string;
  readonly personality: PersonalityMode;
  readonly absenceIntervalSeconds: number;
  readonly quietHoursEnabled: boolean;
  readonly quietHoursStart: string;
  readonly quietHoursEnd: string;
}

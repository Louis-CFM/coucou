/**
 * Normalized AI provider abstraction — Claude Code + OpenAI Codex.
 * Frontend only sees safe status objects (never tokens).
 */

export type ProviderId = "claude-code" | "openai-codex";

/** Companion-facing agent activity (mapped from provider events). */
export type NormalizedAgentState =
  | "idle"
  | "connecting"
  | "thinking"
  | "reading"
  | "searching"
  | "editing"
  | "writing"
  | "running_command"
  | "waiting_for_user"
  | "success"
  | "error";

export interface ProviderAuthInfo {
  provider: ProviderId;
  authenticated: boolean;
  accountLabel?: string | null;
  status: "disconnected" | "connecting" | "waiting" | "connected" | "error";
  error?: string | null;
  loginId?: string | null;
  /** Device-code only — safe to show */
  verificationUrl?: string | null;
  userCode?: string | null;
  mode?: "browser" | "device_code" | null;
}

export interface AIProvider {
  readonly id: ProviderId;
  readonly displayName: string;
  getAuth(): Promise<ProviderAuthInfo>;
  /** Start official ChatGPT browser login when supported. */
  signInWithChatGPT?(): Promise<ProviderAuthInfo>;
  signInWithDeviceCode?(): Promise<ProviderAuthInfo>;
  cancelLogin?(loginId: string): Promise<ProviderAuthInfo>;
  disconnect?(): Promise<ProviderAuthInfo>;
  /** Map provider-specific events → companion state. */
  mapEventToState?(event: unknown): NormalizedAgentState | null;
}

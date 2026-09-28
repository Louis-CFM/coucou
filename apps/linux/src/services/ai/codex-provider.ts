import type { AIProvider, NormalizedAgentState, ProviderAuthInfo } from "./types.js";
import {
  codexCancelLogin,
  codexGetAuthState,
  codexLoginChatGPT,
  codexLoginDeviceCode,
  codexLogout,
  codexStatus,
  isTauri,
} from "../../bridge/tauri.js";
import { logger } from "../../core/logger.js";

function fromBridge(raw: {
  authenticated?: boolean;
  accountLabel?: string | null;
  status?: string;
  error?: string | null;
  loginId?: string | null;
  verificationUrl?: string | null;
  userCode?: string | null;
  mode?: string | null;
}): ProviderAuthInfo {
  const status = (raw.status ?? "disconnected") as ProviderAuthInfo["status"];
  return {
    provider: "openai-codex",
    authenticated: !!raw.authenticated,
    accountLabel: raw.accountLabel ?? null,
    status: ["disconnected", "connecting", "waiting", "connected", "error"].includes(status)
      ? status
      : "disconnected",
    error: raw.error ?? null,
    loginId: raw.loginId ?? null,
    verificationUrl: raw.verificationUrl ?? null,
    userCode: raw.userCode ?? null,
    mode: raw.mode === "device_code" || raw.mode === "browser" ? raw.mode : null,
  };
}

/** OpenAI Codex — official openai-codex Python SDK via Tauri bridge. */
export class CodexProvider implements AIProvider {
  readonly id = "openai-codex" as const;
  readonly displayName = "OpenAI Codex";

  async getAuth(): Promise<ProviderAuthInfo> {
    if (!isTauri()) {
      return {
        provider: "openai-codex",
        authenticated: false,
        status: "disconnected",
        error: null,
      };
    }
    try {
      const s = await codexStatus();
      logger.hook("[Codex] status", s.status);
      return fromBridge(s);
    } catch (e) {
      return {
        provider: "openai-codex",
        authenticated: false,
        status: "error",
        error: e instanceof Error ? e.message : "Codex runtime unavailable",
      };
    }
  }

  async signInWithChatGPT(): Promise<ProviderAuthInfo> {
    logger.hook("[Codex] Starting ChatGPT authentication");
    const s = await codexLoginChatGPT();
    return fromBridge(s);
  }

  async signInWithDeviceCode(): Promise<ProviderAuthInfo> {
    logger.hook("[Codex] Starting device-code authentication");
    const s = await codexLoginDeviceCode();
    return fromBridge(s);
  }

  async cancelLogin(loginId: string): Promise<ProviderAuthInfo> {
    const s = await codexCancelLogin(loginId);
    return fromBridge(s);
  }

  async disconnect(): Promise<ProviderAuthInfo> {
    const s = await codexLogout();
    return fromBridge(s);
  }

  mapEventToState(event: unknown): NormalizedAgentState | null {
    const e = event as { agentState?: string };
    const s = e.agentState;
    const allowed: NormalizedAgentState[] = [
      "idle",
      "connecting",
      "thinking",
      "reading",
      "searching",
      "editing",
      "writing",
      "running_command",
      "waiting_for_user",
      "success",
      "error",
    ];
    if (s && (allowed as string[]).includes(s)) return s as NormalizedAgentState;
    return null;
  }

  /** Cached state without hitting the bridge (after events). */
  async peek(): Promise<ProviderAuthInfo> {
    if (!isTauri()) return this.getAuth();
    return fromBridge(await codexGetAuthState());
  }
}

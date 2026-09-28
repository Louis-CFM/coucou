import type { AIProvider, NormalizedAgentState, ProviderAuthInfo } from "./types.js";
import { hooksInstalled } from "../../bridge/tauri.js";

/** Claude Code provider — hook-based; auth is local Claude Code / VS Code, not ChatGPT. */
export class ClaudeCodeProvider implements AIProvider {
  readonly id = "claude-code" as const;
  readonly displayName = "Claude Code";

  async getAuth(): Promise<ProviderAuthInfo> {
    const installed = await hooksInstalled();
    return {
      provider: "claude-code",
      authenticated: installed,
      accountLabel: installed ? "Hooks installed" : null,
      status: installed ? "connected" : "disconnected",
      error: null,
    };
  }

  mapEventToState(event: unknown): NormalizedAgentState | null {
    const e = event as { hook_event_name?: string };
    switch (e.hook_event_name) {
      case "UserPromptSubmit":
        return "thinking";
      case "PreToolUse":
      case "PostToolUse":
        return "running_command";
      case "PermissionRequest":
        return "waiting_for_user";
      case "Stop":
        return "success";
      case "StopFailure":
        return "error";
      default:
        return null;
    }
  }
}

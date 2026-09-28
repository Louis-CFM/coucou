import { ClaudeCodeProvider } from "./claude-provider.js";
import { CodexProvider } from "./codex-provider.js";
import type { AIProvider, ProviderId } from "./types.js";

const providers: Record<ProviderId, AIProvider> = {
  "claude-code": new ClaudeCodeProvider(),
  "openai-codex": new CodexProvider(),
};

export function getProvider(id: ProviderId): AIProvider {
  return providers[id];
}

export function allProviders(): AIProvider[] {
  return Object.values(providers);
}

export { ClaudeCodeProvider, CodexProvider };
export * from "./types.js";
export { companionStateFromAgent } from "./event-adapter.js";

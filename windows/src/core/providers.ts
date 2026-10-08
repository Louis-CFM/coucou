// Who the chat can talk to — the island's side of chat.rs. The Mac's
// ChatProvider (IslandTypes.swift) plus OpenRouter and any OpenAI-compatible
// server. Pure data and helpers, so they can be tested without a webview.

import type { Settings } from "./state";
import { N_ } from "../i18n/i18n";

export type ProviderId =
  | "anthropic" | "openai" | "google" | "openrouter"
  | "ollama" | "lmstudio" | "custom";

export interface ProviderDef {
  id: ProviderId;
  /** Shown on the chip in the chat's model picker. */
  name: string;
  accent: string;
  /** Credential store entry of its key; null for the model servers. */
  key: string | null;
  /** Settings field holding a model server's address. */
  urlField: "ollamaUrl" | "lmstudioUrl" | "customUrl" | null;
  defaultModel: string;
  /** When the saved model is not offered, the first one containing this is picked. */
  prefer: string | null;
}

export const PROVIDERS: readonly ProviderDef[] = [
  { id: "anthropic", name: "Anthropic", accent: "#E07950", key: "anthropic-api-key", urlField: null, defaultModel: "claude-opus-5", prefer: "opus" },
  { id: "google", name: "Google", accent: "#4285F4", key: "google-api-key", urlField: null, defaultModel: "gemini-2.0-flash", prefer: "flash" },
  { id: "openai", name: "OpenAI", accent: "#10A37F", key: "openai-api-key", urlField: null, defaultModel: "gpt-4o", prefer: "mini" },
  { id: "openrouter", name: "OpenRouter", accent: "#6467F2", key: "openrouter-api-key", urlField: null, defaultModel: "openrouter/auto", prefer: null },
  { id: "ollama", name: "Ollama", accent: "#FACC15", key: null, urlField: "ollamaUrl", defaultModel: "", prefer: null },
  { id: "lmstudio", name: "LM Studio", accent: "#A3E635", key: null, urlField: "lmstudioUrl", defaultModel: "", prefer: null },
  { id: "custom", name: N_("Custom server"), accent: "#C0C4CC", key: null, urlField: "customUrl", defaultModel: "", prefer: null },
];

/** Credential store entry of the custom server's optional key. */
export const CUSTOM_SERVER_KEY = "openai-compatible-key";

export function providerDef(id: string): ProviderDef {
  return PROVIDERS.find((p) => p.id === id) ?? PROVIDERS[0];
}

/** The model the chat uses for the active provider. */
export function activeModel(settings: Settings): string {
  const p = providerDef(settings.chatProvider);
  if (p.id === "anthropic") return settings.model || p.defaultModel;
  return settings.chatModels[p.id] || p.defaultModel;
}

/** `settings` with `model` picked for `provider`. */
export function withModel(settings: Settings, provider: ProviderId, model: string): Settings {
  if (provider === "anthropic") return { ...settings, model };
  return { ...settings, chatModels: { ...settings.chatModels, [provider]: model } };
}

/**
 * The chips of the picker: every cloud provider (one without a key says so
 * when picked), and a model server once it is connected — or while it is the
 * active one, so the picker never hides where the chat goes.
 */
export function visibleProviders(settings: Settings): ProviderDef[] {
  return PROVIDERS.filter(
    (p) => !p.urlField || settings[p.urlField] !== "" || settings.chatProvider === p.id,
  );
}

/** The model to keep once the list arrives: the saved one if offered, else a sensible one. */
export function pickModel(provider: ProviderDef, offered: string[], current: string): string | null {
  if (offered.length === 0) return null;
  if (offered.includes(current)) return current;
  const preferred = provider.prefer ? offered.find((id) => id.includes(provider.prefer!)) : undefined;
  if (preferred) return preferred;
  return offered.includes(provider.defaultModel) ? provider.defaultModel : offered[0];
}

// ── Where an address points ───────────────────────────────────────────────────

/** Mirrors net.rs: this machine, by name or address. */
export function isLoopbackHost(host: string): boolean {
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (h === "localhost" || h.endsWith(".localhost")) return true;
  if (/^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(h)) return true;
  return h === "0.0.0.0" || h === "::1" || h === "::" || h === "::ffff:127.0.0.1" || h === "::ffff:7f00:1";
}

/**
 * Where a server address sends what you type: this machine, another one over
 * https, another one in clear text (http), or nowhere valid. An empty field
 * means the usual address on this machine.
 */
export type Exposure = "local" | "remote" | "remote-http" | "invalid";

export function urlExposure(raw: string): Exposure {
  const text = raw.trim();
  if (!text) return "local";
  let url: URL;
  try {
    url = new URL(text.includes("://") ? text : `http://${text}`);
  } catch {
    return "invalid";
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return "invalid";
  if (!url.hostname || url.username || url.password) return "invalid";
  if (isLoopbackHost(url.hostname)) return "local";
  return url.protocol === "https:" ? "remote" : "remote-http";
}

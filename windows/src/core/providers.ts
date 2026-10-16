// Who the chat can talk to — the island's side of chat.rs. The Mac's
// ChatProvider (IslandTypes.swift) plus OpenRouter and any OpenAI-compatible
// server. Pure data and helpers, so they can be tested without a webview.

import type { Settings } from "./state";
import { N_ } from "../i18n/i18n";

export type ProviderId =
  | "anthropic" | "openai" | "google" | "openrouter"
  | "ollama" | "lmstudio" | "custom"
  | "cursor" | "kiro" | "claude-cli" | "devin" | "codex"
  /** The media models saved in Settings (src-tauri/src/media.rs): "Create". */
  | "media";

export interface ProviderDef {
  id: ProviderId;
  /** Shown on the chip in the chat's model picker. */
  name: string;
  accent: string;
  /** Credential store entry of its key; null for the model servers. */
  key: string | null;
  /** Settings field holding a model server's address. */
  urlField: "ollamaUrl" | "lmstudioUrl" | "customUrl" | null;
  /** A CLI the chat asks instead of an API: the user's own plan, via `agent` / `kiro-cli` / `claude` / `devin` / `codex`. */
  cli: boolean;
  defaultModel: string;
  /** When the saved model is not offered, the first one containing this is picked. */
  prefer: string | null;
}

export const PROVIDERS: readonly ProviderDef[] = [
  { id: "anthropic", name: "Anthropic", accent: "#E07950", key: "anthropic-api-key", urlField: null, cli: false, defaultModel: "claude-opus-5", prefer: "opus" },
  { id: "google", name: "Google", accent: "#4285F4", key: "google-api-key", urlField: null, cli: false, defaultModel: "gemini-2.0-flash", prefer: "flash" },
  { id: "openai", name: "OpenAI", accent: "#10A37F", key: "openai-api-key", urlField: null, cli: false, defaultModel: "gpt-4o", prefer: "mini" },
  { id: "openrouter", name: "OpenRouter", accent: "#6467F2", key: "openrouter-api-key", urlField: null, cli: false, defaultModel: "openrouter/auto", prefer: null },
  { id: "claude-cli", name: N_("Claude Code"), accent: "#E07950", key: null, urlField: null, cli: true, defaultModel: "", prefer: null },
  { id: "cursor", name: "Cursor", accent: "#4C9AFF", key: null, urlField: null, cli: true, defaultModel: "auto", prefer: null },
  { id: "devin", name: N_("Devin"), accent: "#6366F1", key: null, urlField: null, cli: true, defaultModel: "", prefer: null },
  { id: "codex", name: N_("ChatGPT"), accent: "#10A37F", key: null, urlField: null, cli: true, defaultModel: "", prefer: null },
  { id: "kiro", name: "Kiro", accent: "#A259FF", key: null, urlField: null, cli: true, defaultModel: "auto", prefer: null },
  { id: "ollama", name: "Ollama", accent: "#FACC15", key: null, urlField: "ollamaUrl", cli: false, defaultModel: "", prefer: null },
  { id: "lmstudio", name: "LM Studio", accent: "#A3E635", key: null, urlField: "lmstudioUrl", cli: false, defaultModel: "", prefer: null },
  { id: "custom", name: N_("Custom server"), accent: "#C0C4CC", key: null, urlField: "customUrl", cli: false, defaultModel: "", prefer: null },
  // Images, video, speech and 3D from the models saved in Settings -> Media
  // and voice models; its "model" is a saved entry's id.
  { id: "media", name: "Create", accent: "#E879F9", key: null, urlField: null, cli: false, defaultModel: "", prefer: null },
];

/** The saved models the "Create" chip offers. */
export function creators(settings: Settings) {
  return settings.models ?? [];
}

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
 * The chips of the picker: what is set up — a cloud provider whose key is in
 * the credential store (`hasKey`), a model server once it is connected — and
 * always the active one, so the picker never hides where the chat goes. The
 * active one says so when its key is missing; the others are added in
 * Settings, where their keys go.
 */
export function visibleProviders(
  settings: Settings,
  hasKey: (key: string) => boolean = () => false,
  hasCli: (id: ProviderId) => boolean = () => false,
): ProviderDef[] {
  return PROVIDERS.filter((p) => {
    if (settings.chatProvider === p.id) return true;
    if (p.id === "media") return creators(settings).length > 0;
    if (p.cli) return hasCli(p.id);
    if (p.urlField) return settings[p.urlField] !== "";
    return p.key != null && hasKey(p.key);
  });
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

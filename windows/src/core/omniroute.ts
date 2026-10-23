// OmniRoute, the model router the user runs on their computer — the island's
// side of omniroute.rs. Its settings, the commands of its card in Settings →
// Chat, and the pure helpers they use (tested without a webview).

import { invoke } from "@tauri-apps/api/core";
import { IS_TAURI } from "./bridge";
import type { ProviderId } from "./providers";
import type { Settings } from "./state";

/** Settings.omniroute, as omniroute.rs stores it. */
export interface OmniRouteConfig {
  /** In the chat's picker, and started by Coucou at launch. */
  enabled: boolean;
  /** Its address; empty for the usual one on this computer. */
  url: string;
  /** Dictation clean-up, Notetaker summaries and « OK Coucou » go through it. */
  features: boolean;
  /** The model those features ask for. */
  featuresModel: string;
  /** The chat's provider before OmniRoute took it, given back when it is turned off. */
  chatBefore?: ProviderId;
}

const OMNIROUTE_DEFAULTS: OmniRouteConfig = { enabled: false, url: "", features: false, featuresModel: "" };

export const DEFAULT_URL = "http://127.0.0.1:20128";

/** Where it comes from: the npm package, its site and its repository. */
export const INSTALL_COMMAND = "npm install -g omniroute";
export const SITE_URL = "https://omniroute.online";
export const REPO_URL = "https://github.com/diegosouzapw/OmniRoute";

/** What omniroute.rs reports, from scratch each time. */
export interface OmniRouteStatus {
  url: string;
  local: boolean;
  installed: boolean;
  running: boolean;
  key: "none" | "ok" | "missing" | "refused";
  models: string[];
  error: string | null;
}

async function run<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (!IS_TAURI) throw new Error("not running inside Coucou");
  return invoke<T>(cmd, args);
}

export const OmniRouteBridge = {
  status: () => run<OmniRouteStatus>("omniroute_status"),
  /** Resolves once it answers, with its status then. */
  start: () => run<OmniRouteStatus>("omniroute_start"),
  /** Stored for `url` only; an empty key removes it. */
  setKey: (url: string, key: string) => run<void>("omniroute_set_key", { url, key }),
  /** A key is saved for the address in use; asks nothing over the network. */
  keySaved: () => run<boolean>("omniroute_key_saved"),
  dashboard: () => run<void>("omniroute_dashboard"),
};

/** Its settings, whatever an older settings.json left out. */
export function omnirouteConfig(settings: Settings): OmniRouteConfig {
  return { ...OMNIROUTE_DEFAULTS, ...(settings.omniroute ?? {}) };
}

/** The one thing the card says about where it stands, worst first. */
export type Stage = "off" | "unreachable" | "not-installed" | "stopped" | "key" | "refused" | "empty" | "ready";

export function stage(config: OmniRouteConfig, status: OmniRouteStatus | null): Stage {
  if (!config.enabled) return "off";
  if (!status) return "unreachable";
  if (!status.running) return !status.local ? "unreachable" : status.installed ? "stopped" : "not-installed";
  if (status.key === "missing") return "key";
  if (status.key === "refused") return "refused";
  if (status.error) return "unreachable";
  return status.models.length ? "ready" : "empty";
}

/** The model to keep for the features once the list is known: the saved one if offered. */
export function featuresModel(saved: string, offered: string[]): string {
  if (offered.includes(saved)) return saved;
  return offered[0] ?? "";
}

/** The chat's provider once OmniRoute is turned off: the one it had before, if it still went to OmniRoute. */
export function chatAfterOff(chatProvider: ProviderId, config: OmniRouteConfig): ProviderId {
  if (chatProvider !== "omniroute") return chatProvider;
  const before = config.chatBefore;
  return before && before !== "omniroute" ? before : "anthropic";
}

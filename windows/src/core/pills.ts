// Every pill the island can show — port of PillCatalog.swift, the single source
// of truth on macOS. IDs, names, colours, categories and subtitles are the Mac's,
// in the Mac's order: they are contract values (settings, hook routing), so an
// ID here never changes once shipped.
//
// What is added for Windows and Linux is `support` — not every Mac pill has
// something behind it here — and `connect`, which says what makes the pill
// "connected": its hooks being installed, a key in the OS credential store, or
// nothing at all.

import type { AgentSource } from "./state";
import { N_ } from "../i18n/i18n";

export type PillCategory = "workspace" | "agent" | "ai" | "service";

/** Section titles (English keys, shown with `t()`), in display order. */
export const PILL_CATEGORIES: { id: PillCategory; title: string }[] = [
  { id: "workspace", title: N_("Where you code") },
  { id: "agent", title: N_("Agents") },
  { id: "ai", title: N_("AI for the chat") },
  { id: "service", title: N_("Services") },
];

/**
 * Whether the pill does anything on this build:
 * - `yes`: works on Windows and Linux;
 * - `windows`: Windows only (the app behind it has no Linux build);
 * - `linux`: Linux only (what drives it is Linux's: Spotify through MPRIS);
 * - `soon`: can be declared, shows "Coming soon" (macOS has it, this build not yet);
 * - `no`: macOS only, never offered here.
 */
export type PillSupport = "yes" | "windows" | "linux" | "soon" | "no";

/** What makes the pill connected. */
export type PillConnect =
  /** Hook events: connected once the hooks are installed (Mac #183). */
  | { kind: "hooks" }
  /** A key in the credential store. */
  | { kind: "key"; key: string }
  /** A model server the chat is connected to (Settings → Local models). */
  | { kind: "server"; field: "ollamaUrl" | "lmstudioUrl" }
  /** Nothing to set up. */
  | { kind: "none" };

export interface PillDefinition {
  id: string;
  name: string;
  color: string;
  category: PillCategory;
  /** Label next to the pill name in the idle card header (an English key, shown with `t()`). */
  subtitle: string;
  source: AgentSource;
  support: PillSupport;
  connect: PillConnect;
}

export type HostOs = "windows" | "linux";

const hooks: PillConnect = { kind: "hooks" };
const key = (k: string): PillConnect => ({ kind: "key", key: k });
const none: PillConnect = { kind: "none" };
const server = (field: "ollamaUrl" | "lmstudioUrl"): PillConnect => ({ kind: "server", field });

/** ChatProvider.accentHex on macOS. */
const ACCENT = {
  anthropic: "#E07950",
  google: "#4285F4",
  openai: "#10A37F",
  ollama: "#FACC15",
  lmstudio: "#A3E635",
};

export const PILL_CATALOG: readonly PillDefinition[] = [
  // ── Where you code ─────────────────────────────────────────────────────────
  { id: "integration_claude", name: "VS Code", color: "#F5F6F8", category: "workspace",
    subtitle: N_("Integration"), source: "claudeCode", support: "yes", connect: hooks },
  // Claude Code in Cursor's terminal: the same hooks as Claude Code.
  { id: "agent_cursor", name: "Cursor", color: "#C0C4CC", category: "workspace",
    subtitle: N_("Integration"), source: "agent", support: "yes", connect: hooks },
  { id: "agent_antigravity", name: "Antigravity", color: "#E879F9", category: "workspace",
    subtitle: N_("Integration"), source: "agent", support: "yes", connect: hooks },
  { id: "agent_codex", name: "Codex", color: "#2DD4BF", category: "workspace",
    subtitle: N_("Integration"), source: "agent", support: "yes", connect: hooks },
  // ── Agents ─────────────────────────────────────────────────────────────────
  { id: "agent_gemini", name: "Gemini CLI", color: "#8AB4F8", category: "agent",
    subtitle: N_("Agent"), source: "agent", support: "yes", connect: hooks },
  { id: "agent_copilot", name: "Copilot CLI", color: "#818CF8", category: "agent",
    subtitle: N_("Agent"), source: "agent", support: "yes", connect: hooks },
  { id: "agent_muse", name: "Muse Code", color: "#38BDF8", category: "agent",
    subtitle: N_("Agent"), source: "agent", support: "yes", connect: hooks },
  // A plugin that starts the relay, written from Settings → Agents (agents.rs).
  { id: "agent_opencode", name: "OpenCode", color: "#4ADE80", category: "agent",
    subtitle: N_("Agent"), source: "agent", support: "yes", connect: hooks },
  { id: "agent_amp", name: "Amp", color: "#F59E0B", category: "agent",
    subtitle: N_("Agent"), source: "agent", support: "yes", connect: hooks },
  { id: "agent_hermes", name: "Hermes", color: "#C084FC", category: "agent",
    subtitle: N_("Agent"), source: "agent", support: "yes", connect: hooks },
  // Claude Code sessions run from the Claude desktop app: the relay tags them
  // from CLAUDE_CODE_ENTRYPOINT, so there is nothing to install. The app has no
  // Linux build.
  { id: "agent_claude-desktop", name: "Claude Desktop", color: "#D97757", category: "agent",
    subtitle: N_("Agent"), source: "agent", support: "windows", connect: none },
  // ── AI for the chat ────────────────────────────────────────────────────────
  { id: "ai_anthropic", name: "Anthropic", color: ACCENT.anthropic, category: "ai",
    subtitle: N_("Chat"), source: "n8n", support: "yes", connect: key("anthropic-api-key") },
  // The chat talks to each of them (src-tauri/src/chat.rs): a key for the
  // cloud ones, a connected server for the local ones.
  { id: "ai_google", name: "Google AI", color: ACCENT.google, category: "ai",
    subtitle: N_("Chat"), source: "n8n", support: "yes", connect: key("google-api-key") },
  { id: "ai_openai", name: "OpenAI", color: ACCENT.openai, category: "ai",
    subtitle: N_("Chat"), source: "n8n", support: "yes", connect: key("openai-api-key") },
  { id: "ai_ollama", name: "Ollama", color: ACCENT.ollama, category: "ai",
    subtitle: N_("Chat"), source: "n8n", support: "yes", connect: server("ollamaUrl") },
  { id: "ai_lmstudio", name: "LM Studio", color: ACCENT.lmstudio, category: "ai",
    subtitle: N_("Chat"), source: "n8n", support: "yes", connect: server("lmstudioUrl") },
  // ── Services ───────────────────────────────────────────────────────────────
  { id: "integration_resend", name: "Resend", color: "#22C55E", category: "service",
    subtitle: N_("Integration"), source: "n8n", support: "yes", connect: key("resend-api-key") },
  { id: "integration_n8n", name: "n8n", color: "#F29B38", category: "service",
    subtitle: N_("Integration"), source: "n8n", support: "yes", connect: key("n8n-api-key") },
  { id: "integration_vercel", name: "Vercel", color: "#7C5CFF", category: "service",
    subtitle: N_("Integration"), source: "n8n", support: "yes", connect: key("vercel-token") },
  { id: "integration_github", name: "GitHub", color: "#F4505E", category: "service",
    subtitle: N_("Integration"), source: "n8n", support: "yes", connect: key("github-token") },
  { id: "integration_notion", name: "Notion", color: "#8C8C8C", category: "service",
    subtitle: N_("Integration"), source: "n8n", support: "yes", connect: key("notion-api-key") },
  { id: "integration_calcom", name: "Cal.com", color: "#C9956A", category: "service",
    subtitle: N_("Integration"), source: "n8n", support: "yes", connect: key("calcom-api-key") },
  { id: "integration_stripe", name: "Stripe", color: "#0570DE", category: "service",
    subtitle: N_("Integration"), source: "n8n", support: "yes", connect: key("stripe-api-key") },
  // Windows: read from the system media controls (src-tauri/src/media_win.rs).
  { id: "integration_music", name: "Apple Music", color: "#FA2D48", category: "service",
    subtitle: N_("Integration"), source: "n8n", support: "windows", connect: none },
  // Linux: Spotify's MPRIS interface (spotify.rs). Windows: the media controls.
  { id: "integration_spotify", name: "Spotify", color: "#1DB954", category: "service",
    subtitle: N_("Integration"), source: "n8n", support: "yes", connect: none },
  // Windows only: whatever else plays — a browser tab, VLC, Media Player…
  { id: "integration_media", name: "Now Playing", color: "#A78BFA", category: "service",
    subtitle: N_("Integration"), source: "n8n", support: "windows", connect: none },
];

/** The always-on pill unless the user picks another workspace tool. */
export const DEFAULT_MAIN_PILL = "integration_claude";

/** How many declared pills may sit next to the main one. */
export const MAX_DECLARED = 4;

/** The OS this page runs on. Only the Windows webview says "Windows". */
export const HOST_OS: HostOs =
  typeof navigator !== "undefined" && /Windows/.test(navigator.userAgent ?? "") ? "windows" : "linux";

export function pillDefinition(id: string): PillDefinition | undefined {
  return PILL_CATALOG.find((p) => p.id === id);
}

function offeredOn(def: PillDefinition, os: HostOs): boolean {
  return def.support === "yes" || def.support === "soon" || def.support === os;
}

/** The pills this build offers, in catalog order. */
export function availablePills(os: HostOs = HOST_OS): PillDefinition[] {
  return PILL_CATALOG.filter((p) => offeredOn(p, os));
}

export function isComingSoon(id: string): boolean {
  return pillDefinition(id)?.support === "soon";
}

/** True for pills whose sessions arrive as hook events (Mac #183). */
export function isHookPill(id: string): boolean {
  return pillDefinition(id)?.connect.kind === "hooks";
}

/** Workspace tools that can be the main pill. */
export function mainPillChoices(os: HostOs = HOST_OS): PillDefinition[] {
  return availablePills(os).filter((p) => p.category === "workspace" && p.support !== "soon");
}

/** PillDefinition.sessionSubtitle — next to the name in a live session's card. */
export function sessionSubtitle(id: string): string {
  switch (id) {
    case "integration_claude": return "Claude Code";
    case "agent_cursor": return "Cursor";
    case "agent_codex": return "Codex";
    case "agent_hermes": return "Hermes";
    case "agent_claude-desktop": return "Claude Desktop";
    default: return N_("Agent");
  }
}

export interface Declared {
  mainPill: string;
  activeIntegrations: string[];
}

/**
 * The declaration as it may be used: a main pill this build can run (else the
 * default), and declared pills this build offers, without duplicates and
 * without the main pill, which never takes a slot. Same rules as
 * AppState.loadIntegrationTasks on macOS.
 */
export function sanitizeDeclared(d: Declared, os: HostOs = HOST_OS): Declared {
  const mains = new Set(mainPillChoices(os).map((p) => p.id));
  const mainPill = mains.has(d.mainPill) ? d.mainPill : DEFAULT_MAIN_PILL;
  const offered = new Set(availablePills(os).map((p) => p.id));
  const activeIntegrations: string[] = [];
  for (const id of d.activeIntegrations ?? []) {
    if (id !== mainPill && offered.has(id) && !activeIntegrations.includes(id)) {
      activeIntegrations.push(id);
    }
  }
  return { mainPill, activeIntegrations };
}

/**
 * Declares or undeclares a pill. Returns the new list, or null when the click
 * changes nothing: the main pill is never toggled, an unknown pill never
 * declared, and a fifth pill never added.
 */
export function toggleDeclared(d: Declared, id: string, os: HostOs = HOST_OS): string[] | null {
  if (id === d.mainPill) return null;
  if (!availablePills(os).some((p) => p.id === id)) return null;
  if (d.activeIntegrations.includes(id)) return d.activeIntegrations.filter((x) => x !== id);
  if (d.activeIntegrations.length >= MAX_DECLARED) return null;
  return [...d.activeIntegrations, id];
}

/**
 * Picks a new main pill. The old main pill is not declared on its own, and the
 * new one leaves the declared list so it does not take a slot twice.
 */
export function chooseMainPill(d: Declared, id: string, os: HostOs = HOST_OS): Declared | null {
  if (!mainPillChoices(os).some((p) => p.id === id)) return null;
  return { mainPill: id, activeIntegrations: d.activeIntegrations.filter((x) => x !== id) };
}

/**
 * Pill order: the main pill first, then pills from outside the catalog (any
 * other tagged agent), then the catalog's pills in catalog order. Pills of equal
 * rank keep their order. Mirrors sortTasksByCatalog on macOS, with the main
 * pill (not always VS Code here) leading.
 */
export function orderPills<T extends { id: string }>(tasks: T[], mainPill: string): T[] {
  const index = new Map(PILL_CATALOG.map((p, i) => [p.id, i]));
  const rank = (t: T) => (t.id === mainPill ? -2 : index.has(t.id) ? index.get(t.id)! : -1);
  return tasks
    .map((t, i) => ({ t, i }))
    .sort((a, b) => rank(a.t) - rank(b.t) || a.i - b.i)
    .map(({ t }) => t);
}

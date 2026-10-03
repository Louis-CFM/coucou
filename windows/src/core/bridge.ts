// Thin wrapper over the Tauri commands/events. Every call is a no-op when the
// page is opened in a plain browser, so the island can be iterated on with
// `npm run dev` alone.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import type { Settings } from "./state";

export const IS_TAURI =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!IS_TAURI) return null;
  try {
    return await invoke<T>(cmd, args);
  } catch (err) {
    console.error(`[coucou] ${cmd} failed`, err);
    return null;
  }
}

export interface BootInfo {
  settings: Settings;
  /** Logical screen rect of the monitor the island lives on. */
  screen: { x: number; y: number; width: number; height: number; scale: number };
  version: string;
  hookPath: string;
  /** False where the OS has no global cursor (Wayland): see Island.followPageCursor. */
  cursorPoll: boolean;
}

export const Bridge = {
  boot: () => call<BootInfo>("boot"),

  saveSettings: (settings: Settings) => call<void>("save_settings", { settings }),

  /** Shrink the window down to the invisible wake strip (hidden) or back to full. */
  setCollapsed: (collapsed: boolean) => call<void>("set_collapsed", { collapsed }),

  /**
   * Pushes the island shape in window coordinates. Rust flips click-through from
   * its own cursor poll, so the flag is never a frame behind a click.
   */
  setIslandRect: (x: number, y: number, width: number, height: number) =>
    call<void>("set_island_rect", { x, y, width, height }),

  /** Give the window keyboard focus (chat field) and take it away again. */
  focusWindow: (focused: boolean) => call<void>("focus_window", { focused }),

  reposition: () => call<void>("reposition"),

  openUrl: (url: string) => call<void>("open_url", { url }),

  /**
   * "Open Visual Studio Code" → opens the folder in VS Code when `code` is on PATH.
   * With a WSL distro, `path` is a Linux path and opens through Remote WSL.
   */
  openInVSCode: (path: string | null, wslDistro: string | null = null) =>
    call<boolean>("open_in_vscode", { path, wslDistro }),

  /**
   * "Open terminal" → once WSL is set up, brings the session's terminal window
   * forward, or any terminal; with none open, a new one in the session folder
   * (WSL shell for a WSL session). Without WSL: the folder in VS Code.
   */
  openTerminal: (path: string | null, wslDistro: string | null, terminalPids: number[]) =>
    call<boolean>("open_terminal", { path, wslDistro, terminalPids }),

  quit: () => call<void>("quit_app"),

  openSettingsWindow: () => call<void>("open_settings_window"),

  /** Writes to %LOCALAPPDATA%\Coucou\coucou.log, next to the Rust lines. */
  log: (message: string) => call<void>("log_line", { message }),

  // ── Claude Code hooks ─────────────────────────────────────────────────────
  hooksStatus: () => call<HookStatus>("hooks_status"),
  /** Diff to show before anything is written. `install: false` previews removal. */
  hooksPreview: (install: boolean) => callOrThrow<HookPreview>("hooks_preview", { install }),
  /**
   * Writes ~/.claude/settings.json — only ever after an explicit click, and only
   * when the file still matches the preview the user looked at.
   */
  hooksApply: (install: boolean, fingerprint: string) =>
    callOrThrow<string>("hooks_apply", { install, fingerprint }),

  // ── Claude Code under WSL ─────────────────────────────────────────────────
  /** Installed distros. Listing them starts nothing. */
  wslDistros: () => call<string[]>("wsl_distros"),
  /** Starts the distro if it isn't running — only call it when the user is looking. */
  wslStatus: (distro: string) => callOrThrow<WslStatus>("wsl_status", { distro }),
  wslHooksPreview: (distro: string, install: boolean) =>
    callOrThrow<HookPreview>("wsl_hooks_preview", { distro, install }),
  /** Writes the relay script and the distro's settings.json — explicit click only. */
  wslHooksApply: (distro: string, install: boolean, fingerprint: string) =>
    callOrThrow<string>("wsl_hooks_apply", { distro, install, fingerprint }),
  /** The section the settings window was opened for, once ("" for none). */
  takeSettingsSection: () => call<string>("take_settings_section"),
  /** Is that Claude Code signed in? (`claude auth status`; null when unknown) */
  claudeLoggedIn: (target: string) => call<boolean>("claude_logged_in", { target }),

  approvalDecision: (requestId: string, decision: "allow" | "deny") =>
    call<void>("approval_decision", { requestId, decision }),
  /** "The card is up" — until this lands the relay only waits a moment. */
  approvalAck: (requestId: string) => call<void>("approval_ack", { requestId }),
  /** "Nobody can act on this" — Claude Code asks in the terminal right away. */
  approvalDecline: (requestId: string) => call<void>("approval_decline", { requestId }),

  // ── Chat, files, secrets ──────────────────────────────────────────────────
  /** One chat turn. The API key and any file bytes never leave Rust. */
  chatSend: (query: string, context: ChatContext | null) =>
    callOrThrow<{ text: string; session?: string }>("chat_send", { query, context }),

  // ── Mochi's sessions (local Claude Code only) ─────────────────────────────
  sessionsList: () => callOrThrow<SessionInfo[]>("sessions_list"),
  sessionHistory: (id: string) => callOrThrow<HistoryItem[]>("session_history", { id }),
  sessionActive: () => call<ActiveSession>("session_active"),
  sessionSelect: (id: string, cwd: string) => callOrThrow<void>("session_select", { id, cwd }),
  /** Erases the transcript — only after the island's second click. */
  sessionDelete: (id: string) => callOrThrow<void>("session_delete", { id }),
  /** Folder picker, then a new session there. `null` when cancelled. */
  sessionNewInFolder: () => callOrThrow<string | null>("session_new_in_folder"),
  chatReset: () => call<void>("chat_reset"),
  /** Copies a dropped file into the inbox. */
  ingestFile: (path: string) => callOrThrow<DroppedFile>("ingest_file", { path }),
  /** Only ever tells you whether a key exists — never its value. */
  secretPresent: (key: string) => call<boolean>("secret_present", { key }),
  secretSet: (key: string, value: string) => callOrThrow<void>("secret_set", { key, value }),
  secretClear: (key: string) => callOrThrow<void>("secret_clear", { key }),

  // ── Integrations ──────────────────────────────────────────────────────────
  refreshIntegration: (id: string) => call<void>("refresh_integration", { id }),
  /** Opens the configured n8n instance in the browser. */
  openN8n: () => call<void>("open_n8n"),

  /** Tray → Pause. Stops the integration pollers, not just the island. */
  setPaused: (paused: boolean) => call<void>("set_paused", { paused }),
};

export interface IntegrationUpdate {
  id: string;
  data: Record<string, unknown>;
  error: string | null;
  event: { success: boolean; label: string; detail: string | null } | null;
}

export type ChatContext =
  | { kind: "file"; name: string; path: string }
  | { kind: "window"; appName: string; title: string; url?: string };

export interface DroppedFile {
  name: string;
  path: string;
  size: number;
}

export interface HookStatus {
  installed: boolean;
  settingsPath: string;
  hookPath: string;
  hookReady: boolean;
  /** Claude Code on Windows, if installed. */
  claudeCli: string | null;
}

export interface WslStatus {
  distro: string;
  installed: boolean;
  /** Linux paths, as the user knows them. */
  settingsPath: string;
  relayPath: string;
  relayReady: boolean;
  /** Claude Code inside the distro, if installed. */
  claudeCli: string | null;
  /** The distro could not be reached; nothing else is meaningful then. */
  error: string | null;
}

/** A Claude Code session, as listed in Mochi's session menu. */
export interface SessionInfo {
  id: string;
  /** Working folder, as that Claude Code sees it (a Linux path under WSL). */
  cwd: string;
  title: string;
  /** Last change, ms since the epoch. */
  updated: number;
}

export interface HistoryItem {
  role: "user" | "assistant";
  text: string;
}

/** The session Mochi's chat is in. No id yet: a new session (inbox when no cwd). */
export interface ActiveSession {
  backend: string;
  id: string | null;
  cwd: string | null;
}

export interface HookPreview {
  diff: string;
  backup: string;
  settingsPath: string;
  /** Hand back to hooksApply so only the reviewed diff is ever written. */
  fingerprint: string;
}

/** Same as `call`, but surfaces the error so the UI can show what went wrong. */
async function callOrThrow<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (!IS_TAURI) throw new Error("not running inside Coucou");
  return invoke<T>(cmd, args);
}

export type BridgeEvent =
  | { name: "cursor"; payload: { x: number; y: number } }
  | { name: "tray"; payload: string }
  | { name: "hook"; payload: Record<string, unknown> }
  | { name: "screen-changed"; payload: null };

export interface DragDropPayload {
  type: "enter" | "over" | "drop" | "leave";
  paths?: string[];
}

/** Files dragged onto the island. Only reaches us when the window takes the mouse. */
export async function onDragDrop(handler: (e: DragDropPayload) => void) {
  if (!IS_TAURI) return () => {};
  return getCurrentWebview().onDragDropEvent((event) => {
    handler(event.payload as DragDropPayload);
  });
}

export async function onEvent<T>(name: string, handler: (payload: T) => void) {
  if (!IS_TAURI) return () => {};
  return listen<T>(name, (e) => handler(e.payload));
}

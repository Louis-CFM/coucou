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

export interface DesktopMochiSnapshot {
  state: string;
  body_color: string | null;
  focused_id: string | null;
  music_playing: boolean;
  permission_pending: boolean;
}

export interface DesktopMochiRuntime {
  snapshot: DesktopMochiSnapshot | null;
  cursor: { dx: number; dy: number } | null;
  visible: boolean;
  dragging: boolean;
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

  /** "Open terminal" → opens the folder in VS Code when `code` is on PATH. */
  /** Brings the agent's own terminal window forward. False when there is none. */
  focusAgentTerminal: (path: string | null) => call<boolean>("focus_agent_terminal", { path }),
  openInVSCode: (path: string | null) => call<boolean>("open_in_vscode", { path }),

  quit: () => call<void>("quit_app"),

  openSettingsWindow: () => call<void>("open_settings_window"),

  /** Writes to %LOCALAPPDATA%\Coucou\coucou.log, next to the Rust lines. */
  log: (message: string) => call<void>("log_line", { message }),

  // ── Desktop Mochi ──────────────────────────────────────────────────────
  /** Reveals the floating panel, placing it where the rules say. */
  desktopMochiShow: () => call<boolean>("desktop_mochi_show"),
  desktopMochiHide: () => call<void>("desktop_mochi_hide"),
  desktopMochiSetEnabled: (enabled: boolean) => call<void>("desktop_mochi_set_enabled", { enabled }),
  desktopMochiRuntime: () => call<DesktopMochiRuntime>("desktop_mochi_runtime"),
  /** Grabs the panel. Rust records where it was so the drag needs no reads. */
  desktopMochiDragStart: () => call<void>("desktop_mochi_drag_start"),
  /** Persists the final physical position once at drag end. */
  desktopMochiDragEnd: () => call<void>("desktop_mochi_drag_end"),
  desktopMochiSync: (
    state: string,
    bodyColor: string | null,
    focusedId: string | null,
    musicPlaying: boolean,
    permissionPending: boolean,
  ) => call<void>("desktop_mochi_sync", {
    state, bodyColor, focusedId, musicPlaying, permissionPending,
  }),
  /** Writes a frontend diagnostic line to coucou.log. */
  desktopMochiProbe: (msg: string) => call<void>("desktop_mochi_probe", { msg }),

  // ── Music (Windows Global Media Control) ─
  /** Current media session, or null when nothing is publishing one. */
  mediaState: () => call<MediaState | null>("media_state"),
  /**
   * Sends a transport command. Resolves false when the player does not
   * advertise that control, so the card hides the button rather than offering
   * one that would do nothing.
   */
  mediaCommand: (cmd: MediaCommand) => call<boolean>("media_command", { cmd }),

  // ── Agent hooks ──────────────────────────────────────────────────────────
  /** Installed state for one agent's hooks. Omit `agent` for the active one. */
  hooksStatus: (agent?: string) => call<HookStatus>("hooks_status", { agent }),
  /** Diff to show before anything is written. `install: false` previews removal. */
  hooksPreview: (install: boolean, agent?: string) =>
    callOrThrow<HookPreview>("hooks_preview", { agent, install }),
  /**
   * Writes the agent's hook configuration — only ever after an explicit click,
   * and only when the file still matches the preview the user looked at.
   */
  hooksApply: (install: boolean, fingerprint: string, agent?: string) =>
    callOrThrow<string>("hooks_apply", { agent, install, fingerprint }),

  approvalDecision: (requestId: string, decision: "allow" | "deny" | "always", note?: string) =>
    call<void>("approval_decision", { requestId, decision, note: note ?? null }),
  /** "The card is up" — until this lands the relay only waits a moment. */
  approvalAck: (requestId: string) => call<void>("approval_ack", { requestId }),
  /** "Nobody can act on this" — Claude Code asks in the terminal right away. */
  approvalDecline: (requestId: string) => call<void>("approval_decline", { requestId }),

  // ── Chat, files, secrets ──────────────────────────────────────────────────
  /** One chat turn. The API key and any file bytes never leave Rust. */
  chatSend: (query: string, context: ChatContext | null) =>
    callOrThrow<{ text: string }>("chat_send", { query, context }),
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

/** A media session published by some player, via Global Media Control. */
export interface MediaState {
  /** App user-model id, e.g. "Spotify.exe". Reverse-DNS ids come through too. */
  app: string;
  title: string;
  artist: string;
  /** Frequently empty: not every player publishes one. Never assume it is there. */
  album: string;
  playing: boolean;
  /** A player exists but has not published a track yet. */
  idle: boolean;
}

export type MediaCommand = "playPause" | "next" | "previous";

export interface HookStatus {
  installed: boolean;
  /**
   * Whether Coucou wrote this file and may therefore update or remove it. False
   * means something else is there — an extension you edited yourself — which
   * Coucou will not overwrite.
   */
  managed: boolean;
  settingsPath: string;
  hookPath: string;
  hookReady: boolean;
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

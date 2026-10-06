// Thin wrapper over the Tauri commands/events. Every call is a no-op when the
// page is opened in a plain browser, so the island can be iterated on with
// `npm run dev` alone.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import type { Settings } from "./state";
import type { ChatAction, SessionSnapshot, TaskAgent, TaskOutcome, TaskTarget } from "./task";
import type { RobotStatus } from "./robot";

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
}

export const Bridge = {
  boot: () => call<BootInfo>("boot"),

  saveSettings: (settings: Settings) => call<void>("save_settings", { settings }),
  saveSettingsStrict: (settings: Settings) => callOrThrow<void>("save_settings", { settings }),

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
  openInVSCode: (path: string | null) => call<boolean>("open_in_vscode", { path }),

  /**
   * Brings the window the agent session started from to the front (a hidden
   * tray window is shown again). Without a live window, a Claude Code session
   * falls back to opening its folder as openInVSCode does; other agents open
   * nothing.
   */
  focusOrigin: (
    hwnd: number | null,
    pid: number | null,
    cwd: string | null,
    agent: string,
    consolePid: number | null = null,
    sessionId: string | null = null,
  ) => call<boolean>("focus_origin", { hwnd, pid, cwd, agent, consolePid, sessionId }),

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

  agentHooksStatus: (agent: AgentId) =>
    callOrThrow<AgentHookStatus>("agent_hooks_status", { agent }),
  agentHooksPreview: (agent: AgentId, install: boolean) =>
    callOrThrow<AgentHookPreview>("agent_hooks_preview", { agent, install }),
  agentHooksApply: (agent: AgentId, install: boolean, fingerprint: string) =>
    callOrThrow<string>("agent_hooks_apply", { agent, install, fingerprint }),

  // ── One-step agent setup ──────────────────────────────────────────────────
  /** Which of Claude, Codex, Kimi and Hermes are on this machine. Read-only. */
  agentsDetect: () => callOrThrow<DetectedAgent[]>("agents_detect"),
  /** Installs hooks for every detected agent — only from the Settings button. */
  agentsSetupAll: () => callOrThrow<SetupReport>("agents_setup_all"),
  /** The first-launch offer was answered (or dismissed): do not offer again. */
  agentsSetupDismiss: () => call<void>("agents_setup_dismiss"),
  /** Opens Settings with "Set up all my agents" highlighted. Installs nothing. */
  openSettingsForSetup: () => call<void>("open_settings_for_setup"),

  approvalDecision: (requestId: string, decision: "allow" | "deny") =>
    call<void>("approval_decision", { requestId, decision }),
  /** Claude AskUserQuestion picks: one label list per question, by index. */
  approvalAnswers: (requestId: string, answers: string[][]) =>
    call<void>("approval_answers", { requestId, answers }),
  /** "The card is up" — until this lands the relay only waits a moment. */
  approvalAck: (requestId: string) => call<void>("approval_ack", { requestId }),
  /** "Nobody can act on this" — Claude Code asks in the terminal right away. */
  approvalDecline: (requestId: string) => call<void>("approval_decline", { requestId }),

  hermesClarifyPending: (sessionId: string) =>
    callOrThrow<{ hermes: number; entries: HermesPending[] }>("hermes_clarify_pending", { sessionId }),
  hermesClarifyAnswer: (pid: number, kind: string, id: string, answers: string[][]) =>
    callOrThrow<HermesAnswered>("hermes_clarify_answer", { pid, kind, id, answers }),

  /**
   * "+ New task". Rust validates, launches, types the prompt only into a
   * verified window, and remembers the folder and target. Throws a readable error.
   */
  launchTask: (agent: TaskAgent, target: TaskTarget, folder: string, prompt: string) =>
    callOrThrow<TaskOutcome>("launch_task", { agent, target, folder, prompt }),

  /** Native folder picker (tauri-plugin-dialog). null = cancelled or not in Tauri. */
  pickFolder: async (startIn: string): Promise<string | null> => {
    if (!IS_TAURI) return null;
    const picked = await openDialog({
      directory: true,
      multiple: false,
      title: "Choose the project folder",
      defaultPath: startIn.trim() || undefined,
    });
    return typeof picked === "string" ? picked : null;
  },

  // ── Robot (background agent in the hidden browser) ────────────────────────
  robotStatus: () => call<RobotStatus>("robot_status"),
  /** Starts a task; throws "busy" while another one runs. */
  robotStart: (task: string) => callOrThrow<RobotStatus>("robot_start", { task }),
  /** Kills the agent's process tree. */
  robotStop: () => call<RobotStatus>("robot_stop"),
  /** JPEG data URL of the hidden browser's active page, null when none. Read-only. */
  robotPreview: () => callOrThrow<string | null>("robot_preview"),
  robotApprove: (id: string, allow: boolean) => call<boolean>("robot_approve", { id, allow }),

  // ── Chat, files, secrets ──────────────────────────────────────────────────
  /**
   * One chat turn. The API key and any file bytes never leave Rust. The chat
   * may start agent tasks; `actions` lists what it ran. `sessions` feeds its
   * read-only list_sessions tool.
   */
  chatSend: (query: string, context: ChatContext | null, sessions: SessionSnapshot[]) =>
    callOrThrow<{ text: string; actions: ChatAction[]; memoryStatus: string | null; turnId: string | null }>("chat_send", { query, context, sessions }),
  chatReset: () => call<void>("chat_reset"),
  chatPrivate: (enabled: boolean) => callOrThrow<void>("chat_private", { enabled }),
  rememberTurn: (turnId: string) => callOrThrow<ArtifactSummary>("remember_turn", { turnId }),
  rememberSelection: (turnId: string, text: string, start: number, end: number) =>
    callOrThrow<ArtifactSummary>("remember_selection", { turnId, text, start, end }),
  prepareForgetTurn: (turnId: string) => callOrThrow<PrepareForgetSummary>("prepare_forget_turn", { turnId }),
  forgetTurn: (confirmation: PrepareForgetSummary) => callOrThrow<ForgetTurnResult>("forget_turn", { confirmation }),
  openMemoryWindow: (request: { query?: string; documentIds?: string[] } = {}) => call<void>("open_memory_window", { query: request.query ?? null, documentIds: request.documentIds ?? [] }),
  memoryWindowReady: () => callOrThrow<void>("memory_window_ready"),
  hindsightTestConnection: () => callOrThrow<void>("hindsightTestConnection"),
  memoryList: (request: MemoryBrowseRequest) => callOrThrow<MemoryPage>("memoryList", { request }),
  memoryGet: (id: string) => callOrThrow<MemoryRecord>("memoryGet", { id }),
  memorySafeDetail: (id: string) => callOrThrow<SafeMemoryDetail>("memorySafeDetail", { id }),
  memoryUpdate: (id: string, opened: MemoryRecord, update: MemoryUpdate, overwrite = false) =>
    callOrThrow<MemoryUpdateResult>("memoryUpdate", { id, opened, update, overwrite }),
  memoryRetire: (confirmation: ConfirmedMemoryRetirement) => callOrThrow<MemoryMutationResult>("memoryRetire", { confirmation }),
  memoryRestore: (id: string) => callOrThrow<MemoryMutationResult>("memoryRestore", { id }),
  memoryBulkRetire: (scope: ConfirmedMemoryScope) => callOrThrow<BulkMutationResult>("memoryBulkRetire", { scope }),
  memoryExport: (records: MemoryRecord[], format: "json" | "markdown") =>
    callOrThrow<MemoryExport>("memoryExport", { records, format }),
  memorySaveExport: (exported: MemoryExport) => callOrThrow<boolean>("memorySaveExport", { exported }),
  /**
   * Model ids from the 9router (cached 5 min in Rust). Throws a readable error.
   * `baseUrl` tests a URL that has not been saved yet.
   */
  routerModels: (refresh = false, baseUrl?: string) =>
    callOrThrow<string[]>("router_models", { refresh, baseUrl: baseUrl ?? null }),
  /** Validates and normalises a 9router base URL with the Rust rules. */
  routerNormalizeUrl: (url: string) => callOrThrow<string>("router_normalize_url", { url }),
  /** Copies a dropped file into the inbox. */
  ingestFile: (path: string) => callOrThrow<DroppedFile>("ingest_file", { path }),
  /** Only ever tells you whether a key exists — never its value. */
  secretPresent: (key: string) => call<boolean>("secret_present", { key }),
  secretSet: (key: string, value: string) => callOrThrow<void>("secret_set", { key, value }),
  secretClear: (key: string) => callOrThrow<void>("secret_clear", { key }),
  hindsightBearerTokenPresent: () => call<boolean>("secret_present", { key: "hindsight-bearer-token" }),
  hindsightBearerTokenSet: (value: string) =>
    callOrThrow<void>("secret_set", { key: "hindsight-bearer-token", value }),
  hindsightBearerTokenDelete: () =>
    callOrThrow<void>("secret_clear", { key: "hindsight-bearer-token" }),

  // ── Integrations ──────────────────────────────────────────────────────────
  refreshIntegration: (id: string) => call<void>("refresh_integration", { id }),
  /** Opens the configured n8n instance in the browser. */
  openN8n: () => call<void>("open_n8n"),

  /** Tray → Pause. Stops the integration pollers, not just the island. */
  setPaused: (paused: boolean) => call<void>("set_paused", { paused }),

  // ── Island position ───────────────────────────────────────────────────────
  /** Unlocked only: Windows moves the island with the mouse; Rust saves the spot on release. */
  islandStartDrag: () => call<void>("island_start_drag"),
  islandSetLocked: (locked: boolean) => call<void>("island_set_locked", { locked }),
  /** Back to the top centre of the chosen display. */
  islandResetPosition: () => call<void>("island_reset_position"),

  // ── Hotkeys, quick windows, voice ─────────────────────────────────────────
  /** What the last registration of the three global hotkeys gave. */
  hotkeysStatus: () => call<HotkeyStatus[]>("hotkeys_status"),
  /** Same rules as Rust: "ctrl+alt+k" → "Ctrl+Alt+K"; throws a readable reason. */
  hotkeyNormalize: (combo: string) => callOrThrow<string>("hotkey_normalize", { combo }),
  /** Steps Coucou's own hotkeys aside while Settings records one (on=false puts them back). */
  hotkeysSuspend: (on: boolean) => call<HotkeyStatus[]>("hotkeys_suspend", { on }),
  quickHide: (label: QuickLabel) => call<void>("quick_hide", { label }),
  quickShow: (label: QuickLabel) => call<void>("quick_show", { label }),
  /** Tells the other windows the chat log changed, so they show the same conversation. */
  chatHistoryChanged: (history: unknown, from: string) => call<void>("chat_history_changed", { history, from }),
  microphoneStatus: () => call<MicStatus>("microphone_status"),
  openMicrophoneSettings: () => call<void>("open_microphone_settings"),
  /** Raw recording → text, through the 9router. Throws a readable error. */
  voiceTranscribe: async (audio: ArrayBuffer, mime: string): Promise<string> => {
    if (!IS_TAURI) throw new Error("not running inside Coucou");
    return invoke<string>("voice_transcribe", audio, { headers: { "x-audio-type": mime } });
  },
};

export type QuickLabel = "quick-chat" | "quick-task" | "quick-robot";

export interface HermesPending {
  kind: "gateway" | "desktop";
  id: string;
  questions: { qid: string; question: string; choices: string[]; multiSelect: boolean }[];
  matched: string;
  pid: number;
}

export interface HermesAnswered { ok: boolean; reason: string }

export interface HotkeyStatus {
  action: "chat" | "task" | "voice" | "robot";
  combo: string;
  registered: boolean;
  error: string | null;
}

export interface MicStatus {
  blocked: boolean;
  message: string;
}

export interface IntegrationUpdate {
  id: string;
  data: Record<string, unknown>;
  error: string | null;
  event: { success: boolean; label: string; detail: string | null } | null;
}

export type MemoryState = "valid" | "invalidated";
export type MemoryFactType = "world" | "experience" | "observation";
export interface MemoryFilter {
  query?: string;
  documentId?: string;
  factType?: MemoryFactType;
  state: MemoryState;
  startDate?: string;
  endDate?: string;
  timeField?: "created_at" | "updated_at" | "mentioned_at" | "occurred_start" | "occurred_end" | "edited_at";
  platform?: "windows" | "macos";
  retentionKind?: "explicit" | "inferred";
  sourceKind?: "chat" | "selected-text";
}
export interface MemoryBrowseRequest { filter: MemoryFilter; limit: number; offset: number }
export interface ConfirmedMemoryScope { request: MemoryBrowseRequest; endpoint: string; tenant: string; bank: string; fingerprint: string }
export interface ConfirmedMemoryRetirement { id: string; text: string; updatedAt?: string; endpoint: string; tenant: string; bank: string }
export interface ArtifactSummary { artifactCount: number; remoteIdCount: number; hasPending: boolean; documentIds: string[] }
export interface PrepareForgetSummary { turnId: string; generation: number; endpoint: string; tenant: string; bank: string; knownIds: string[]; documentIds: string[]; artifactFingerprint: string }
export interface DiscoveryFailure { documentId: string; kind: string; message: string }
export interface ForgetTurnResult { requested: number; retired: string[]; failed: { id: string; kind: string; message: string }[]; documentIds: string[]; discoveryFailures: DiscoveryFailure[]; fallback?: "document" | "text" }
export interface MemoryRecord {
  id: string; text: string; factType: MemoryFactType; state: MemoryState; context?: string;
  metadata: Record<string, unknown>; tags: string[]; entities: string[]; documentId?: string;
  chunkId?: string; createdAt?: string; updatedAt?: string; mentionedAt?: string;
  occurredStart?: string; occurredEnd?: string; editedAt?: string; sourceFactIds: string[];
}
export interface SafeMemoryDetail {
  id: string; content: string; factType: MemoryFactType; state: MemoryState; tenant: string; bank: string; context?: string;
  metadata: Record<string, string>; tags: string[]; entities: string[]; documentId?: string; chunkId?: string;
  createdAt?: string; updatedAt?: string; mentionedAt?: string; occurredStart?: string; occurredEnd?: string; editedAt?: string; sourceFactIds: string[];
}
export interface MemoryPage { items: MemoryRecord[]; total: number; limit: number; offset: number }
export interface MemoryUpdate {
  text?: string; context?: string; occurredStart?: string; occurredEnd?: string;
  factType?: MemoryFactType; entities?: string[]; resolveEntities?: boolean;
  state?: MemoryState; reason?: string; expectedUpdatedAt?: string;
}
export type MemoryUpdateResult = { kind: "updated"; memory: MemoryRecord; refresh: boolean } | { kind: "conflict"; current: MemoryRecord };
export interface MemoryMutationResult { memory: MemoryRecord; refresh: boolean }
export interface BulkMutationResult { requested: number; succeeded: string[]; failed: { id: string; kind: string; message: string }[]; refresh: boolean }
export interface MemoryExport { content: string; filename: string }

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
}

export interface HookPreview {
  diff: string;
  backup: string;
  settingsPath: string;
  /** Hand back to hooksApply so only the reviewed diff is ever written. */
  fingerprint: string;
}

export type AgentId = "kimi-code" | "codex" | "hermes";

export interface DetectedAgent {
  agent: SetupAgentId;
  label: string;
  cli: string | null;
  desktop: string | null;
  configDir: string | null;
  found: boolean;
  configured: boolean;
}

export type SetupAgentId = "claude" | AgentId;

export type SetupOutcome =
  | "installed" | "already-set-up" | "would-install" | "removed" | "would-remove"
  | "not-installed" | "skipped" | "error";

export interface SetupAgentResult {
  agent: SetupAgentId;
  label: string;
  outcome: SetupOutcome;
  message: string;
  detectedBy: string;
  warning: string;
  settingsPath: string;
  backup: string;
  followUp: string;
}

export interface SetupReport {
  action: "setup" | "remove";
  dryRun: boolean;
  relay: string;
  relayReady: boolean;
  relayMessage: string;
  agents: SetupAgentResult[];
  ok: boolean;
}

export interface AgentHookStatus {
  /** Hooks can be installed: CLI on PATH, or desktop app / config folder found. */
  available: boolean;
  cliFound: boolean;
  compatible: boolean;
  version: string;
  versionState: "tested" | "untested" | "unknown" | "missing";
  versionReason: string;
  testedVersion: string;
  versionWarning: string;
  configured: boolean;
  trustVerified: boolean;
  liveEventSeen: boolean;
  settingsPath: string;
  hookPath: string;
  hookReady: boolean;
  detail: string;
}

export interface AgentHookPreview {
  versionWarning: string;
  diff: string;
  fingerprint: string;
  backup: string;
  settingsPath: string;
  hookPath: string;
  hookReady: boolean;
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

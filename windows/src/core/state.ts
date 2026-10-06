// App state — mirror of AppState.swift (the parts the island needs).

import type { BotEmoteName, BotStateName, IslandMode, IslandViewName } from "./layout";
import type { EyeShape } from "../mochi/engine";
import { IDLE_ROBOT, type RobotStatus } from "./robot";
import { PendingMemoryStatuses } from "./memory-status";

export type AgentSource = "claudeCode" | "n8n" | "agent";
export type PillBadge = "approval" | "finished" | "error";

export function taskId(agent: string, sessionId: string): string {
  return `agent:${encodeURIComponent(agent)}:${encodeURIComponent(sessionId)}`;
}

export interface AgentTask {
  id: string;
  name: string;
  color: string;
  state: BotStateName;
  stepIndex: number;
  steps: string[];
  source: AgentSource;
  isIntegration: boolean;
  emote?: BotEmoteName | null;
  miniEye?: EyeShape | null;
  pillBadge?: PillBadge | null;
  sessionCwd?: string | null;
  /** Top-level window the session started from, as reported by coucou-hook. */
  originHwnd?: number | null;
  originPid?: number | null;
  originConsolePid?: number | null;
  agent?: string;
  sessionId?: string;
  lastEventAt?: number;
  /** An external agent's open question, shown until its next event. Read-only, except Hermes'. */
  questions?: QuestionInfo[] | null;
  picks?: string[][];
  step?: number;
  questionStatus?: string | null;
  /** A Kimi/Hermes approval shown read-only (`tool · command`) until its next event. */
  approvalNotice?: string | null;
}

export function sessionDiscriminator(sessionId: string): string {
  let hash = 2166136261;
  for (const byte of new TextEncoder().encode(sessionId)) {
    hash = Math.imul(hash ^ byte, 16777619) >>> 0;
  }
  return `#${hash.toString(16).padStart(8, "0")}`;
}

const AGENT_NAMES: Record<string, string> = {
  claude: "Claude",
  codex: "Codex",
  "kimi-code": "Kimi",
  hermes: "Hermes",
};

/** Short display name for an agent id: "kimi-code" → "Kimi". */
export function agentDisplayName(task: Pick<AgentTask, "agent" | "source" | "name">): string {
  if (task.source === "claudeCode") return "Claude";
  const id = task.agent ?? "";
  if (AGENT_NAMES[id]) return AGENT_NAMES[id];
  const raw = id || task.name;
  return raw ? raw.charAt(0).toUpperCase() + raw.slice(1) : "Agent";
}

/**
 * Sessions of the same agent in the same project, numbered 1, 2, … in the
 * order they appear. 0 when the task is the only one (no number needed).
 */
export function sessionOrdinal(task: AgentTask, tasks: readonly AgentTask[]): number {
  if (!task.sessionId) return 0;
  const twins = tasks.filter((t) => t.sessionId != null && t.agent === task.agent && t.name === task.name);
  if (twins.length < 2) return 0;
  return twins.indexOf(task) + 1;
}

/** Pill text: "Claude · coucou", or "Claude · coucou 2" for a second session in the same project. */
export function sessionLabel(task: AgentTask, tasks: readonly AgentTask[] = []): string {
  const agent = agentDisplayName(task);
  if (!task.sessionId) return agent;
  const n = sessionOrdinal(task, tasks);
  return n ? `${agent} · ${task.name} ${n}` : `${agent} · ${task.name}`;
}

/** Hover text with the full detail, including the stable session fingerprint. */
export function sessionTitle(task: AgentTask, tasks: readonly AgentTask[] = []): string {
  const label = sessionLabel(task, tasks);
  return task.sessionId ? `${label}\nSession ${sessionDiscriminator(task.sessionId)}` : label;
}

/**
 * Whether "Open" can bring something up for this session: its origin window,
 * or — for Claude Code only — its folder in VS Code. Codex, Kimi and Hermes
 * sessions without a known window have nothing to open (an editor would be the
 * wrong app for a desktop-app or terminal session).
 */
export function canOpenOrigin(task: AgentTask | null): boolean {
  if (!task || (task.source !== "agent" && task.source !== "claudeCode")) return false;
  if (task.originHwnd != null) return true;
  return task.source === "claudeCode" && (!!task.sessionCwd || !task.sessionId);
}

export interface SessionOrigin {
  hwnd: number;
  pid: number;
  /** A process on the session's console, used to pick the terminal tab. */
  consolePid?: number | null;
}

export interface QuestionOption {
  label: string;
  description?: string;
}

/** One multiple-choice question as the agent asked it. */
export interface QuestionInfo {
  question: string;
  header?: string;
  multiSelect: boolean;
  options: QuestionOption[];
}

export interface ApprovalInfo {
  requestId: string;
  sessionId: string;
  taskId: string;
  tool: string;
  command: string;
  /** Claude AskUserQuestion: the questions to answer instead of Allow/Deny. */
  questions?: QuestionInfo[];
  /** Picked labels per question index, in option order. */
  picks?: string[][];
  /** Index of the question on screen; the card asks one question at a time. */
  step?: number;
}

export interface ChatMessage {
  id: number;
  /** "action": a system line for a task the chat started (or tried to). */
  role: "user" | "assistant" | "action";
  content: string;
  actionKind?: "ok" | "paste" | "error";
  turnId?: string;
  memoryStatus?: "saving" | "saved" | "notSaved";
}

export type PromptContext =
  | { kind: "window"; appName: string; title: string; url?: string }
  | { kind: "file"; name: string; path?: string };

export interface ResultItem {
  label: string;
  detail: string;
  url?: string;
}

export interface SearchResult {
  title: string;
  items: ResultItem[];
  note?: string;
}

const task = (
  id: string, name: string, color: string, source: AgentSource,
): AgentTask => ({
  id, name, color, state: "idle", stepIndex: 0, steps: [], source, isIntegration: true,
});

/** Built-in integration prototypes; live agent sessions are added separately. */
export const INTEGRATION_AGENTS: AgentTask[] = [
  task("integration_claude", "Claude Code", "#F5F6F8", "claudeCode"),
  task("integration_resend", "Resend", "#22C55E", "n8n"),
  task("integration_n8n", "n8n", "#F29B38", "n8n"),
  task("integration_vercel", "Vercel", "#7C5CFF", "n8n"),
  task("integration_github", "GitHub", "#F4505E", "n8n"),
  task("integration_notion", "Notion", "#8C8C8C", "n8n"),
  task("integration_calcom", "Cal.com", "#C9956A", "n8n"),
  task("integration_stripe", "Stripe", "#0570DE", "n8n"),
];

export const TOGGLEABLE_INTEGRATION_IDS = [
  "integration_resend", "integration_n8n", "integration_vercel", "integration_github",
  "integration_notion", "integration_calcom", "integration_stripe",
];

/** What an integration poller last reported. */
export interface IntegrationInfo {
  data: Record<string, unknown>;
  error: string | null;
  loaded: boolean;
  configured: boolean;
}

export interface HindsightSettings {
  enabled: boolean;
  baseUrl: string;
  tenant: string;
  bank: string;
  automaticRecall: boolean;
  inferredRetention: boolean;
  allowDevelopmentHttp: boolean;
}

export interface Settings {
  soundEnabled: boolean;
  soundVolume: number;
  autoCloseInterval: number;
  absenceInterval: number;
  activeIntegrations: string[];
  screen: "primary" | "cursor";
  autostart: boolean;
  hooksInstalled: boolean;
  /** Model used by the chat — a Claude id, or a 9router id when chatProvider is "router". */
  model: string;
  /** Which backend the island chat talks to. */
  chatProvider: ChatProvider;
  /** OpenAI-compatible 9router base URL, e.g. https://host/9router/v1. */
  routerBaseUrl: string;
  /** "+ New task": folder used last time. Written by Rust after each launch. */
  lastTaskFolder: string;
  /** "+ New task": "cli" | "desktop" last used per agent id. */
  lastTaskTargets: Record<string, string>;
  /** "+ New task": saved per "agent/target" key, e.g. "claude/cli". No prompts. */
  taskProfiles: Record<string, { folder: string }>;
  /** Global hotkeys, e.g. "Ctrl+Alt+Space". "" = off. */
  hotkeys: Hotkeys;
  /** Speech-to-text model sent to the 9router's /audio/transcriptions. */
  sttModel: string;
  /** Locked: the island stays put. Unlocked: drag it anywhere. */
  islandLocked: boolean;
  /** Top centre of the island in physical px; null = default top centre. Written by Rust only. */
  islandPosition: { x: number; y: number } | null;
  /** The first-launch "Set them up?" offer was already made. */
  setupOffered: boolean;
  /** Robot agents in fallback order: "hermes:<profile>", "hermes", "codex". */
  robotAgents: string[];
  /** Robot actions that run without an Allow/Deny card (matched strictly). */
  robotPreapproved: string[];
  /** Starts the hidden browser when it is not answering on 127.0.0.1:9222. */
  robotBrowserStart: string;
  hindsight: HindsightSettings;
}

export interface Hotkeys {
  chat: string;
  task: string;
  voice: string;
  robot: string;
}

export type ChatProvider = "anthropic" | "router";

export const DEFAULT_SETTINGS: Settings = {
  soundEnabled: true,
  soundVolume: 0.12,
  autoCloseInterval: 15,
  absenceInterval: 180,
  activeIntegrations: [
    "integration_resend", "integration_n8n", "integration_vercel", "integration_github",
  ],
  screen: "primary",
  autostart: false,
  hooksInstalled: false,
  model: "claude-opus-5",
  chatProvider: "anthropic",
  routerBaseUrl: "",
  lastTaskFolder: "",
  lastTaskTargets: {},
  taskProfiles: {},
  hotkeys: { chat: "Ctrl+Alt+C", task: "Ctrl+Alt+N", voice: "Ctrl+Alt+V", robot: "Ctrl+Alt+R" },
  sttModel: "groq/whisper-large-v3",
  islandLocked: true,
  islandPosition: null,
  setupOffered: false,
  robotAgents: ["hermes:amanda", "codex"],
  robotPreapproved: [],
  robotBrowserStart: "",
  hindsight: {
    enabled: false,
    baseUrl: "https://hindsight.example.com/hindsight",
    tenant: "default",
    bank: "hieu",
    automaticRecall: true,
    inferredRetention: true,
    allowDevelopmentHttp: false,
  },
};

type Listener = () => void;

class AppState {
  mode: IslandMode = "hidden";
  view: IslandViewName = "overview";

  tasks: AgentTask[] = [];
  focusId: string | null = null;

  stateOverride: BotStateName | null = null;

  /** Cursor in logical screen pixels, origin top-left (like AppState.mousePosition). */
  mouse = { x: 0, y: 0 };
  /** Cursor relative to the island's top-left corner. */
  mouseInIsland = { x: 0, y: 0 };

  isPinned = false;
  paused = false;

  uploadProgress = 0;
  uploadDuration = 2.4;
  fileDragOver = false;

  promptContext: PromptContext | null = null;
  droppedFile: { name: string; path: string } | null = null;
  noteMessage: string | null = null;
  /** First launch: agents Coucou found that are not hooked up yet. */
  setupOffer: string[] = [];
  searchResult: SearchResult | null = null;
  chatHistory: ChatMessage[] = [];
  /** Session-only. It deliberately never appears in Settings or local storage. */
  privateChat = false;
  memoryStatus: string | null = null;
  pendingMemoryStatuses = new PendingMemoryStatuses(128);
  pendingApproval: ApprovalInfo | null = null;
  /** Last status the robot reported (src-tauri/src/robot.rs). */
  robot: RobotStatus = { ...IDLE_ROBOT };

  integrations: Record<string, IntegrationInfo> = {};

  lastActivity = performance.now();

  settings: Settings = { ...DEFAULT_SETTINGS };

  private listeners = new Set<Listener>();

  subscribe(fn: Listener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  /** Marks the UI dirty; the island re-renders on the next frame. */
  notify() {
    for (const fn of this.listeners) fn();
  }

  get focusTask(): AgentTask | null {
    return this.tasks.find((t) => t.id === this.focusId) ?? this.tasks[0] ?? null;
  }

  get effectiveState(): BotStateName {
    return this.stateOverride ?? this.focusTask?.state ?? "idle";
  }

  get otherTasks(): AgentTask[] {
    return this.tasks.filter((t) => t.id !== this.focusId);
  }

  setFocus(id: string) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    const previous = this.focusTask;
    this.focusId = id;
    if (previous && previous.id !== id && this.pendingApproval?.taskId === previous.id) previous.pillBadge = "approval";
    if (t.pillBadge !== "approval" || this.pendingApproval?.taskId !== id) t.pillBadge = null;
    this.notify();
  }

  /** The view a session's pill opens on: its pending card, else its outcome. */
  sessionView(id: string): IslandViewName | null {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return null;
    if (this.pendingApproval?.taskId === id) return "approval";
    if (t.approvalNotice) return "notice";
    if (t.questions?.length) return "question";
    if (t.pillBadge === "finished") return "finished";
    if (t.pillBadge === "error") return "error";
    return null;
  }

  updateTask(id: string, state: BotStateName) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    t.state = state;
    this.notify();
  }

  appendStep(id: string, step: string) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    t.steps.push(step);
    if (t.steps.length > 20) t.steps.shift();
    t.stepIndex = t.steps.length - 1;
    this.notify();
  }

  setPillBadge(id: string, badge: PillBadge | null) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    t.pillBadge = badge;
    this.notify();
  }

  /** Keep the legacy Claude pill available; other built-in integrations are opt-in. */
  loadIntegrationTasks() {
    for (const proto of INTEGRATION_AGENTS) {
      const shouldLoad =
        proto.id === "integration_claude" || this.settings.activeIntegrations.includes(proto.id);
      const idx = this.tasks.findIndex((t) => t.id === proto.id);
      if (shouldLoad && idx < 0) this.tasks.push({ ...proto, steps: [] });
      if (!shouldLoad && idx >= 0) this.tasks.splice(idx, 1);
    }
    // Keep the legacy Claude integration first, live sessions next, and
    // opt-in integrations in declaration order. The pill rail scrolls past four.
    const order = INTEGRATION_AGENTS.map((t) => t.id);
    this.tasks.sort((a, b) => {
      if (a.id === "integration_claude") return -1;
      if (b.id === "integration_claude") return 1;
      if (a.sessionId && !b.sessionId) return -1;
      if (b.sessionId && !a.sessionId) return 1;
      if (a.sessionId && b.sessionId) return 0;
      return order.indexOf(a.id) - order.indexOf(b.id);
    });
    if (!this.focusId) this.focusId = "integration_claude";
    this.notify();
  }

  removeTask(id: string) {
    const idx = this.tasks.findIndex((t) => t.id === id);
    if (idx < 0) return;
    this.tasks.splice(idx, 1);
    if (this.focusId === id) this.focusId = this.tasks[0]?.id ?? "integration_claude";
    this.notify();
  }

  upsertAgentSession(agent: string, sessionId: string, projectName: string, cwd: string, origin?: SessionOrigin | null): AgentTask {
    const id = taskId(agent, sessionId);
    let t = this.tasks.find((item) => item.id === id);
    if (!t) {
      let h = 0;
      for (let i = 0; i < agent.length; i++) h = (Math.imul(31, h) + agent.charCodeAt(i)) | 0;
      const colors = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"];
      t = {
        id, agent, sessionId, name: projectName || "Session", color: agent === "claude" ? "#F5F6F8" : colors[(h >>> 0) % colors.length],
        state: "idle", stepIndex: 0, steps: [],
        source: agent === "claude" ? "claudeCode" : "agent", isIntegration: false,
      };
      let lastSession = -1;
      for (let i = 0; i < this.tasks.length; i++) {
        if (this.tasks[i].sessionId != null) lastSession = i;
      }
      const afterClaude = this.tasks.findIndex((item) => item.id === "integration_claude") + 1;
      this.tasks.splice(lastSession >= 0 ? lastSession + 1 : afterClaude, 0, t);
      if (!this.focusId) this.focusId = id;
    }
    if (projectName) t.name = projectName;
    if (cwd) t.sessionCwd = cwd;
    if (origin) {
      t.originHwnd = origin.hwnd;
      t.originPid = origin.pid;
      t.originConsolePid = origin.consolePid ?? null;
    }
    t.lastEventAt = Date.now();
    this.notify();
    return t;
  }

  toggleIntegration(id: string) {
    if (id === "integration_claude") return;
    const active = this.settings.activeIntegrations;
    if (active.includes(id)) {
      this.settings.activeIntegrations = active.filter((x) => x !== id);
      if (this.focusId === id) this.focusId = "integration_claude";
    } else {
      if (active.length >= 4) return;
      this.settings.activeIntegrations = [...active, id];
    }
    this.loadIntegrationTasks();
  }

  defaultView(): IslandViewName {
    return this.tasks.length === 0 ? "empty" : "overview";
  }
}

export const State = new AppState();

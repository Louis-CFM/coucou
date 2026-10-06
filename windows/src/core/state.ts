// App state — mirror of AppState.swift (the parts the island needs).

import type { BotEmoteName, BotStateName, IslandMode, IslandViewName } from "./layout";
import type { EyeShape } from "../mochi/engine";

export type AgentSource = "claudeCode" | "n8n" | "agent";
export type PillBadge = "approval" | "finished" | "error";

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
}

export interface ApprovalInfo {
  requestId: string;
  sessionId: string;
  tool: string;
  command: string;
}

export interface ChatMessage {
  id: number;
  role: "user" | "assistant";
  content: string;
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

/** AgentTask.integrationAgents — same ids, names and colours as macOS. */
export const INTEGRATION_AGENTS: AgentTask[] = [
  task("integration_claude", "VS Code", "#F5F6F8", "claudeCode"),
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

export const ANTIGRAVITY_TASK: AgentTask = {
  id: "agent_antigravity",
  name: "Antigravity",
  color: "#E879F9",
  state: "idle",
  stepIndex: 0,
  steps: [],
  source: "agent",
  isIntegration: false,
};

export interface Settings {
  soundEnabled: boolean;
  soundVolume: number;
  autoCloseInterval: number;
  absenceInterval: number;
  activeIntegrations: string[];
  screen: "primary" | "cursor";
  autostart: boolean;
  hooksInstalled: boolean;
  alwaysShowCompact: boolean;
  chatProvider: "local" | "claude";
  localProvider: "ollama" | "lmstudio" | "unsloth" | "custom";
  localServerUrl: string;
  localModel: string;
  voiceEnabled: boolean;
  voiceWakeWord: string;
  voiceLanguage: "id-ID" | "en-US";
  voiceTtsVoice: string;
  voiceSttProvider: "native" | "whisper";
  voiceWhisperUrl: string;
  voiceSilenceTimeout: number;
  voiceSpeed: number;
  voiceVolume: number;
  voicePitch: string;
  voiceResponseMode: "concise" | "full";
  voiceInputDevice: string;
  voiceMicGain: number;
  /** Claude model used by the chat. */
  model: string;
  webAccessEnabled: boolean;
}

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
  alwaysShowCompact: true,
  chatProvider: "local",
  localProvider: "ollama",
  localServerUrl: "http://localhost:11434",
  localModel: "",
  voiceEnabled: true,
  voiceWakeWord: "Hey Coucou",
  voiceLanguage: "id-ID",
  voiceTtsVoice: "id-ID-GadisNeural",
  voiceSttProvider: "native",
  voiceWhisperUrl: "http://localhost:11434",
  voiceSilenceTimeout: 1.5,
  voiceSpeed: 1.0,
  voiceVolume: 1.0,
  voicePitch: "+0Hz",
  voiceResponseMode: "concise",
  voiceInputDevice: "",
  voiceMicGain: 2.0,
  model: "claude-opus-5",
  webAccessEnabled: true,
};

type Listener = () => void;

class AppState {
  mode: IslandMode = "hidden";
  view: IslandViewName = "overview";

  tasks: AgentTask[] = [];
  focusId: string | null = null;
  mainPillId: string = "agent_antigravity";

  stateOverride: BotStateName | null = null;

  /** Cursor in logical screen pixels, origin top-left (like AppState.mousePosition). */
  mouse = { x: 0, y: 0 };
  /** Cursor relative to the island's top-left corner. */
  mouseInIsland = { x: 0, y: 0 };

  isPinned = false;
  paused = false;
  isVoiceListening = false;
  isVoiceTranscribing: boolean = false;
  isVoiceSpeaking = false;
  voiceListeningPrompt: string | null = null;
  isWebSearching: boolean = false;

  uploadProgress = 0;
  uploadDuration = 2.4;
  fileDragOver = false;

  promptContext: PromptContext | null = null;
  droppedFile: { name: string; path: string } | null = null;
  noteMessage: string | null = null;
  searchResult: SearchResult | null = null;
  chatHistory: ChatMessage[] = [];
  pendingApproval: ApprovalInfo | null = null;

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
    this.focusId = id;
    t.pillBadge = null;
    this.notify();
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

  /** loadIntegrationTasks() — Antigravity & VS Code always on, the rest opt-in (max 4). */
  loadIntegrationTasks() {
    if (!this.tasks.some((t) => t.id === "agent_antigravity")) {
      this.tasks.unshift({ ...ANTIGRAVITY_TASK, steps: [] });
    }
    for (const proto of INTEGRATION_AGENTS) {
      const shouldLoad =
        proto.id === "integration_claude" || this.settings.activeIntegrations.includes(proto.id);
      const idx = this.tasks.findIndex((t) => t.id === proto.id);
      if (shouldLoad && idx < 0) this.tasks.push({ ...proto, steps: [] });
      if (!shouldLoad && idx >= 0) this.tasks.splice(idx, 1);
    }
    // Order: mainPillId (agent_antigravity) at index 0, followed by integration_claude,
    // then dynamic agent_* pills, then integration pills in declaration order.
    const order = INTEGRATION_AGENTS.map((t) => t.id);
    this.tasks.sort((a, b) => {
      if (a.id === this.mainPillId) return -1;
      if (b.id === this.mainPillId) return 1;
      if (a.id === "integration_claude") return -1;
      if (b.id === "integration_claude") return 1;
      const isAgentA = a.id.startsWith("agent_");
      const isAgentB = b.id.startsWith("agent_");
      if (isAgentA && !isAgentB) return -1;
      if (isAgentB && !isAgentA) return 1;
      if (isAgentA && isAgentB) return 0;
      return order.indexOf(a.id) - order.indexOf(b.id);
    });
    if (!this.focusId) this.focusId = this.mainPillId;
    this.notify();
  }

  removeTask(id: string) {
    if (id === this.mainPillId || id === "agent_antigravity") return;
    const idx = this.tasks.findIndex((t) => t.id === id);
    if (idx < 0) return;
    this.tasks.splice(idx, 1);
    if (this.focusId === id) this.focusId = this.tasks[0]?.id ?? this.mainPillId;
    this.notify();
  }

  /** Creates or updates dynamic agent_ pill. Inserted right after mainPillId. */
  upsertExternalAgent(id: string, name: string, color: string) {
    const existing = this.tasks.find((t) => t.id === id);
    if (existing) {
      existing.name = name;
      existing.color = color;
      this.notify();
      return;
    }
    const mainIdx = this.tasks.findIndex((t) => t.id === this.mainPillId);
    const at = mainIdx >= 0 ? mainIdx + 1 : 0;
    this.tasks.splice(at, 0, {
      id, name, color,
      state: "idle", stepIndex: 0, steps: [],
      source: "agent", isIntegration: false,
    });
    if (!this.focusId) this.focusId = id;
    this.notify();
  }

  toggleIntegration(id: string) {
    if (id === "integration_claude") return;
    const active = this.settings.activeIntegrations;
    if (active.includes(id)) {
      this.settings.activeIntegrations = active.filter((x) => x !== id);
      if (this.focusId === id) this.focusId = this.mainPillId;
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

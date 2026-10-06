// App state — mirror of AppState.swift (the parts the island needs).

import type { BotEmoteName, BotStateName, IslandMode, IslandViewName } from "./layout";
import type { EyeShape } from "../mochi/engine";
import type { IntegrationNews } from "./bridge";

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
  /** For an edit: what it would do to its file, to read before allowing it. */
  proposal: FileProposal | null;
}

/** An edit that has not happened yet, as the diff it would make. */
export interface FileProposal {
  path: string;
  patch: string;
  additions: number;
  deletions: number;
  truncated: boolean;
  /** The file does not exist yet. */
  created: boolean;
}

/** One thing Claude asks with its question tool, as the tool words it. */
export interface Question {
  question: string;
  /** A word or two saying what the question is about. */
  header: string | null;
  options: { label: string; description: string | null }[];
  multiSelect: boolean;
}

/** A question Claude is waiting on — up to four at once, answered together. */
export interface QuestionInfo {
  requestId: string;
  sessionId: string;
  questions: Question[];
}

/** The app a Claude Code session runs in. */
export type ClaudeClient = "desktop" | "vscode" | "terminal";

/** What the Claude pill is called while it follows a session from that app. */
export const CLIENT_NAMES: Record<ClaudeClient, string> = {
  desktop: "Claude",
  vscode: "VS Code",
  terminal: "Terminal",
};
/** Until a session has spoken, the pill keeps the name it always had. */
export const CLIENT_UNKNOWN = "VS Code";

/** One edit Claude made to a file: its unified diff, as coucou-hook built it. */
export interface FileEdit {
  patch: string;
  additions: number;
  deletions: number;
  /** The diff was longer than the relay forwards. */
  truncated: boolean;
  at: number;
}

/** A file Claude touched in a session, with every edit it made to it, oldest first. */
export interface ChangedFile {
  /** Relative to the session's folder when it is inside it, with forward slashes. */
  path: string;
  /** Written new in this session. */
  created: boolean;
  additions: number;
  deletions: number;
  edits: FileEdit[];
  at: number;
}

/** A few lines of what a tool gave back, as coucou-hook forwards them. */
export interface StepResult {
  text: string;
  /** For a file: the number of its first line. */
  start: number | null;
  /** There was more than this. */
  truncated: boolean;
  /** These are the last lines, not the first: what a command ended on. */
  tail: boolean;
}

/** The tool Claude asks its questions with. */
export const QUESTION_TOOL = "AskUserQuestion";

/** The step that closes a turn, in the place of a tool's name. */
export const TURN_DONE = "Done";

/**
 * What a line of a session's journal is: a tool, by what it does as far as
 * showing it goes — or something said: what the user asked (`prompt`), what
 * Claude answered to end its turn (`reply`), a word from Claude Code (`note`).
 */
export type StepKind = "read" | "edit" | "command" | "search" | "other" | "prompt" | "reply" | "note";

/** The kinds of step that are words, not a tool at work. */
const SAID: ReadonlySet<StepKind> = new Set<StepKind>(["prompt", "reply", "note"]);

/**
 * One line of a session's journal, in the order things happened: a tool by
 * its own name — going, done, or failed — or something that was said.
 */
export interface SessionStep {
  tool: string;
  kind: StepKind;
  state: "running" | "done" | "failed";
  /**
   * What a tool is at: a file by its path in the session's folder, a command,
   * what is looked for. For something said: the words.
   */
  target: string | null;
  /** What it gave back, once it is done. */
  result: StepResult | null;
  /** For an edit: the diff it made. */
  patch: string | null;
  /** For Claude's question tool: what it asks, and once answered, what was picked for each. */
  questions: Question[] | null;
  answers: Record<string, string> | null;
  /** For a tool that had to ask first: where its permission request stands. */
  permission: "asked" | "allowed" | "denied" | null;
  /** When it started; once it has ended, when it ended. */
  at: number;
}

/** A step with nothing in it yet but what it is. */
export function newStep(tool: string, kind: StepKind, target: string | null): SessionStep {
  return {
    tool, kind, state: kind === "prompt" || kind === "reply" || kind === "note" ? "done" : "running",
    target, result: null, patch: null, questions: null, answers: null, permission: null, at: Date.now(),
  };
}

/** The tools of the turn under way: what the session did since it was last asked something. */
export function turnSteps(session: ClaudeSession): SessionStep[] {
  const asked = session.steps.map((step) => step.kind).lastIndexOf("prompt");
  return session.steps.slice(asked + 1).filter((step) => !SAID.has(step.kind));
}

/**
 * A Claude Code session the island knows of. There can be several at once —
 * two conversations in the Claude app, one more in a terminal — and one of
 * them is in front: the one the Claude pill, the cards and the panel show.
 */
export interface ClaudeSession {
  id: string;
  client: ClaudeClient | null;
  /** The conversation's title, when Claude Code has given it one. */
  title: string | null;
  /** The folder it works in: by its name, and whole. */
  project: string;
  cwd: string | null;
  state: BotStateName;
  /** What it did, a line per step, oldest first: what a card falls back on. */
  lines: string[];
  /** Its journal, oldest first: what was asked, each tool, what Claude said; "Done" closes a turn. */
  steps: SessionStep[];
  /** What the user asked last, and what Claude said to end its turn. */
  asked: string | null;
  answer: string | null;
  /** When that answer came. */
  answeredAt: number;
  /** What it is waiting on a human for: a permission, or a question. One at a time. */
  approval: ApprovalInfo | null;
  question: QuestionInfo | null;
  /** What happened here while another session was in front, until it is looked at. */
  news: PillBadge | null;
  /** When it was last heard from. */
  heardAt: number;
}

/** What a session is called before its folder is known. */
export const SESSION_UNNAMED = "Session";

export function newSession(id: string): ClaudeSession {
  return {
    id, client: null, title: null, project: SESSION_UNNAMED, cwd: null, state: "idle",
    lines: [], steps: [], asked: null, answer: null, answeredAt: 0,
    approval: null, question: null, news: null, heardAt: 0,
  };
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

/** The pill that follows Claude Code sessions. */
export const CLAUDE_ID = "integration_claude";

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
  /** What just happened, for as long as the pill says it. */
  news?: IntegrationNews | null;
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
  /** Claude model used by the chat. */
  model: string;
  /** GitHub projects ("owner/name") whose news the pill keeps to itself. */
  githubMuted: string[];
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
  model: "claude-opus-5",
  githubMuted: [],
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
  searchResult: SearchResult | null = null;
  chatHistory: ChatMessage[] = [];

  /** Every session the island knows of, in the order they were first heard. */
  sessions: ClaudeSession[] = [];
  /** The session in front; empty when there is none. */
  frontId = "";
  /** What stands for the session in front while there is none. */
  private readonly noSession = newSession("");
  /** What each session changed, by session id. */
  changes = new Map<string, ChangedFile[]>();

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

  /** The session in front: the one the Claude pill, the cards and the panel show. */
  get session(): ClaudeSession {
    return this.sessions.find((s) => s.id === this.frontId) ?? this.noSession;
  }

  /** What the session in front is waiting on a human for. */
  get pendingApproval(): ApprovalInfo | null {
    return this.session.approval;
  }

  get pendingQuestion(): QuestionInfo | null {
    return this.session.question;
  }

  /** The other sessions waiting on a human, the one that has waited longest first. */
  get waiting(): ClaudeSession[] {
    return this.sessions.filter((s) => s.id !== this.frontId && (s.approval != null || s.question != null));
  }

  /**
   * Puts a session in front. The one it takes the place of keeps going where
   * it runs; if it was waiting for an answer, its tab says so.
   */
  bringForward(id: string) {
    const from = this.session;
    if (from.id && from.id !== id && (from.approval || from.question)) from.news = "approval";
    this.frontId = id;
    this.session.news = null;
    this.present();
  }

  /** The Claude pill wears the session in front: its project, its state, its steps. */
  present() {
    const t = this.tasks.find((x) => x.id === CLAUDE_ID);
    if (!t) return;
    const s = this.session;
    t.name = s.id ? s.project : this.clientName;
    t.state = s.state;
    t.steps = s.lines;
    t.stepIndex = Math.max(0, s.lines.length - 1);
    t.sessionCwd = s.cwd;
    this.notify();
  }

  /** The Claude pill's name: the app of the session it follows. */
  get clientName(): string {
    return this.session.client ? CLIENT_NAMES[this.session.client] : CLIENT_UNKNOWN;
  }

  /** The files the session being followed has changed, the last touched first. */
  get sessionFiles(): ChangedFile[] {
    return this.changes.get(this.session.id) ?? [];
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

  /** loadIntegrationTasks() — VS Code always on, the rest opt-in (max 4). */
  loadIntegrationTasks() {
    for (const proto of INTEGRATION_AGENTS) {
      const shouldLoad =
        proto.id === "integration_claude" || this.settings.activeIntegrations.includes(proto.id);
      const idx = this.tasks.findIndex((t) => t.id === proto.id);
      if (shouldLoad && idx < 0) this.tasks.push({ ...proto, steps: [] });
      if (!shouldLoad && idx >= 0) this.tasks.splice(idx, 1);
    }
    // Order: integration_claude first, then agent_* pills (visible in slice(0,4)),
    // then other integrations in declaration order.
    const order = INTEGRATION_AGENTS.map((t) => t.id);
    this.tasks.sort((a, b) => {
      const isAgentA = a.id.startsWith("agent_");
      const isAgentB = b.id.startsWith("agent_");
      // integration_claude always first
      if (a.id === "integration_claude") return -1;
      if (b.id === "integration_claude") return 1;
      // agent_* before other integrations; preserve insertion order among themselves
      if (isAgentA && !isAgentB) return -1;
      if (isAgentB && !isAgentA) return 1;
      if (isAgentA && isAgentB) return 0;
      // both known integrations → declaration order
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

  /** Creates a dynamic agent_ pill on first event; no-ops if it already exists.
   *  Inserted right after integration_claude so it appears in the visible slice(0,4). */
  upsertExternalAgent(id: string, name: string, color: string) {
    if (this.tasks.some((t) => t.id === id)) return;
    const at = this.tasks.findIndex((t) => t.id === "integration_claude") + 1;
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

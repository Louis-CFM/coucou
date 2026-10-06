// App state — mirror of AppState.swift (the parts the island needs).

import type { BotEmoteName, BotStateName, IslandMode, IslandViewName } from "./layout";
import type { EyeShape } from "../mochi/engine";

// "local" covers pills fed by something other than an agent hook or the n8n
// pollers — the music pill comes from Global Media Control. It behaves like an
// agent pill for state purposes: permanent, never torn down on session end.
export type AgentSource = "claudeCode" | "n8n" | "agent" | "local";
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
  /** Which agent's pill asked — Claude Code, Pi, Copilot CLI or Antigravity. */
  agentId: string;
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
  task("agent_pi", "Pi", "#8B5CF6", "agent"),
  task("agent_copilot", "Copilot CLI", "#58A6FF", "agent"),
  task("agent_antigravity", "Antigravity", "#E879F9", "agent"),
  task("agent_codex", "Codex", "#2DD4BF", "agent"),
  task("integration_resend", "Resend", "#22C55E", "n8n"),
  task("integration_n8n", "n8n", "#F29B38", "n8n"),
  task("integration_vercel", "Vercel", "#7C5CFF", "n8n"),
  task("integration_github", "GitHub", "#F4505E", "n8n"),
  task("integration_notion", "Notion", "#8C8C8C", "n8n"),
  task("integration_calcom", "Cal.com", "#C9956A", "n8n"),
  task("integration_stripe", "Stripe", "#0570DE", "n8n"),
  // Windows-only: driven from Global Media Control rather than polled over the
  // network. Source is "local" so nothing tries to attach a poller to it.
  task("integration_music", "Music", "#FA2D48", "local"),
];

export const TOGGLEABLE_INTEGRATION_IDS = [
  "integration_resend", "integration_n8n", "integration_vercel", "integration_github",
  "integration_notion", "integration_calcom", "integration_stripe",
  "integration_music",
];

const AGENT_PREFIX = "agent_";

/**
 * How many pills exist in total: one focused card plus four minimised ones.
 *
 * Agents and integrations draw on one shared budget, and VS Code counts like
 * anything else now that it can be switched off. Enabling GitHub and one agent
 * is 2 of 5.
 *
 * The cap used to live only in the settings screen — which counted integrations
 * alone. That is why switching an agent off did nothing to the pill row, and why
 * five permanently-on agent pills crowded out every integration.
 */
export const MAX_PILLS = 5;

/** The agent name for an `agent_…` pill id, or null if this is not an agent pill. */
function agentNameOf(id: string): string | null {
  if (id === "integration_claude") return "claudeCode";
  return id.startsWith(AGENT_PREFIX) ? id.slice(AGENT_PREFIX.length) : null;
}

/**
 * The integrations that genuinely count as pills.
 *
 * Agent ids are stripped: an older build used to record enabled agents in
 * `activeIntegrations`, so real settings files still carry `agent_pi` and
 * friends there. Counting them would spend a slot twice — once as an agent and
 * once as an integration — and a file with three leftover ids read as 6 of 4.
 * Agents are governed by `disabledAgents` alone now.
 */
function countedIntegrations(active: string[]): string[] {
  return active.filter((id) => !id.startsWith(AGENT_PREFIX));
}

/** What an integration poller last reported. */
export interface IntegrationInfo {
  data: Record<string, unknown>;
  error: string | null;
  loaded: boolean;
  configured: boolean;
}

export interface Settings {
  soundEnabled: boolean;
  soundVolume: number;
  autoCloseInterval: number;
  absenceInterval: number;
  activeIntegrations: string[];
  screen: "primary" | "cursor";
  autostart: boolean;
  /** Mochi also lives on the desktop as a free-floating, draggable pet. */
  desktopMochi: boolean;
  /** Desktop Mochi's square panel size in logical pixels. */
  desktopMochiSize: number;
  hooksInstalled: boolean;
  /** Which agent's hooks this build drives by default. */
  activeAgent: "pi" | "copilot" | "antigravity" | "codex" | "claudeCode";
  /** Claude model used by the chat. */
  model: string;
  /**
   * Which backend the island chat talks to.
   *
   * Deliberately not a model: Pi is a whole agent with its own authentication
   * and sessions, so it gets its own provider rather than a name on the model
   * list. Optional so a settings object from an older build still type-checks;
   * the Rust side defaults it to "claude".
   */
  chatProvider?: "claude" | "pi";
  /**
   * Agents Coucow has been told to stay away from.
   *
   * A disabled agent's hooks are removed, so the agent stops calling Coucou, and
   * its pill is hidden, so it stops taking up room in the island. A new agent
   * added by a later Coucou is enabled by default rather than silently off.
   */
  disabledAgents?: string[];
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
  desktopMochi: false,
  desktopMochiSize: 120,
  hooksInstalled: false,
  activeAgent: "pi",
  model: "claude-opus-5",
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
  pendingApproval: ApprovalInfo | null = null;

  integrations: Record<string, IntegrationInfo> = {};

  lastActivity = performance.now();

  settings: Settings = { ...DEFAULT_SETTINGS };

  /**
   * Whether an Anthropic key is stored, refreshed from Rust.
   *
   * Kept off `Settings` on purpose: it is derived from the Credential Manager, not
   * a preference, and `save_settings` writes the whole settings object — leaving it
   * there would persist a snapshot of a secret's existence into settings.json.
   *
   * The island's API dot used to be a hardcoded red, which claimed the chat could
   * not work even with a key saved, and would have been worse for Pi, which needs
   * no key at all. This is the real answer.
   */
  anthropicKeyPresent = false;

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

  /**
   * Per-agent hook installation state, refreshed from Rust at boot and whenever
   * settings change. Keyed by agent name ("claudeCode", "pi", "copilot",
   * "antigravity"). Absent means "not checked yet": the UI shows that as unknown
   * rather than pretending an agent is hooked up when it may not be.
   */
  hooksInstalledByAgent: Record<string, boolean> = {};

  setHooksInstalled(agent: string, installed: boolean) {
    this.hooksInstalledByAgent[agent] = installed;
    this.notify();
  }

  /** Whether this agent's hooks are installed. null = not known yet. */
  isAgentHooked(agent: string): boolean | null {
    return this.hooksInstalledByAgent[agent] ?? null;
  }

  /**
   * Rebuilds the pill row.
   *
   * A pill is here if it is switched on *and* there is still budget for it. An
   * agent the user switched off is not here at all — previously every `agent_`
   * pill loaded unconditionally, so turning Copilot off removed its hooks but
   * left its pill sitting in the island looking switched on.
   *
   * Budget runs out in declaration order, so what you get is stable across
   * restarts rather than depending on the order things were clicked.
   */
  loadIntegrationTasks() {
    const disabled = new Set(this.settings.disabledAgents ?? []);
    const previous = new Map(this.tasks.map((t) => [t.id, t]));

    const wanted = (id: string): boolean => {
      const agent = agentNameOf(id);
      if (agent) return !disabled.has(agent);
      return this.settings.activeIntegrations.includes(id);
    };

    // VS Code leads because it is the pill the island opens on, then everything
    // else competes for the budget in declaration order.
    const chosen: string[] = [];
    let budget = MAX_PILLS;
    for (const proto of INTEGRATION_AGENTS) {
      if (!wanted(proto.id) || budget <= 0) continue;
      chosen.push(proto.id);
      budget--;
    }

    // Pills for agents we do not declare — a third-party tool talking to the
    // relay — are kept rather than dropped mid-session. They spend budget too,
    // because they occupy the same space in the row.
    for (const t of this.tasks) {
      if (chosen.includes(t.id) || INTEGRATION_AGENTS.some((p) => p.id === t.id)) continue;
      const agent = agentNameOf(t.id);
      if (agent && disabled.has(agent)) continue;
      if (budget <= 0) break;
      chosen.push(t.id);
      budget--;
    }

    // Reuse the live object where there is one, so steps, badge and state
    // survive a settings change. Rebuilding from the template would wipe the
    // event history of every pill each time a switch was flipped.
    this.tasks = chosen
      .map((id) => previous.get(id) ?? INTEGRATION_AGENTS.find((p) => p.id === id))
      .filter((t): t is AgentTask => Boolean(t));

    // Keep the focused pill first; settings only controls which pills are enabled.
    const order = INTEGRATION_AGENTS.map((t) => t.id);
    this.tasks.sort((a, b) => {
      if (a.id === this.focusId) return -1;
      if (b.id === this.focusId) return 1;
      if (a.id === "integration_claude") return -1;
      if (b.id === "integration_claude") return 1;
      const isAgentA = a.id.startsWith("agent_");
      const isAgentB = b.id.startsWith("agent_");
      if (isAgentA && !isAgentB) return -1;
      if (isAgentB && !isAgentA) return 1;
      return order.indexOf(a.id) - order.indexOf(b.id);
    });
    if (!this.focusId || !this.tasks.some((t) => t.id === this.focusId)) {
      // Never fall back to VS Code: it can now be switched off like anything
      // else, and focusing a pill that does not exist leaves the island blank
      // with no obvious cause.
      this.focusId = this.tasks[0]?.id ?? "";
    }
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
    // An agent the user switched off must not get a pill back just by running.
    // Its hooks were removed, so anything it now reports is not something Coucou
    // asked for, and showing the pill would undo the switch in the UI.
    const agent = agentNameOf(id);
    if (agent && (this.settings.disabledAgents ?? []).includes(agent)) return;
    // The cap covers the focused pill too, so the row is one focused card plus
    // MAX_PILLS-1 minimised ones. An external agent arriving mid-session must
    // not push it wider than the island can lay out.
    if (this.tasks.length >= MAX_PILLS) return;
    const at = this.tasks.findIndex((t) => t.id === "integration_claude") + 1;
    this.tasks.splice(at, 0, {
      id, name, color,
      state: "idle", stepIndex: 0, steps: [],
      source: "agent", isIntegration: false,
    });
    if (!this.focusId) this.focusId = id;
    this.notify();
  }

  /**
   * How much of MAX_PILLS is spent.
   *
   * Every enabled pill counts, Claude Code included: it has a switch in
   * settings, so a switch that did not spend a slot would be a switch whose
   * effect could be undone by enabling something else.
   */
  pillBudgetUsed(): number {
    const disabled = new Set(this.settings.disabledAgents ?? []);
    const agents = INTEGRATION_AGENTS.filter((t) => {
      const agent = agentNameOf(t.id);
      return agent !== null && !disabled.has(agent);
    }).length;
    return agents + countedIntegrations(this.settings.activeIntegrations).length;
  }

  /**
   * True when the pill budget is full and nothing else can be added.
   *
   * Callers show this rather than silently ignoring the click: a switch that
   * refuses to flip and says nothing is indistinguishable from a broken one.
   */
  pillBudgetFull(): boolean {
    return this.pillBudgetUsed() >= MAX_PILLS;
  }

  /** Returns false when the budget was full and nothing changed. */
  toggleIntegration(id: string): boolean {
    // Claude Code is governed by disabledAgents like every other agent; there is
    // no path that enables or disables it through activeIntegrations.
    if (id === "integration_claude") return true;
    const active = this.settings.activeIntegrations;
    if (active.includes(id)) {
      this.settings.activeIntegrations = active.filter((x) => x !== id);
      if (this.focusId === id) this.focusId = "integration_claude";
      this.loadIntegrationTasks();
      return true;
    }
    // Counted against the shared budget, so four enabled agents already fill it
    // and this refuses rather than overflowing the island.
    if (this.pillBudgetFull()) return false;
    this.settings.activeIntegrations = [...active, id];
    this.loadIntegrationTasks();
    return true;
  }

  defaultView(): IslandViewName {
    return this.tasks.length === 0 ? "empty" : "overview";
  }
}

export const State = new AppState();

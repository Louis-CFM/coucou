import type {
  AgentTask,
  ApprovalInfo,
  BotState,
  IslandMode,
  IslandView,
  PillBadge,
} from "./types.js";

export type ChatRole = "user" | "assistant";

export interface ChatMessage {
  id: string;
  role: ChatRole;
  content: string;
}

export interface PromptContextWindow {
  kind: "window";
  appName: string;
  title: string;
  url: string | null;
}

export interface PromptContextFile {
  kind: "file";
  name: string;
  filePath: string | null;
}

export type PromptContext = PromptContextWindow | PromptContextFile;

export interface DroppedFile {
  path: string;
  name: string;
}

export interface SearchResultItem {
  label: string;
  detail: string;
  url?: string;
}

export interface SearchResult {
  title: string;
  items: SearchResultItem[];
  note?: string;
}

export interface VercelDeployment {
  id: string;
  projectName: string;
  url: string;
  state: string;
  createdAt: string;
  commitMessage?: string;
  branch?: string;
}

export interface ResendEmail {
  id: string;
  to: string[];
  subject: string;
  createdAt: string;
  lastEvent: string;
}

export interface GitHubStats {
  totalRepos: number;
  totalStars: number;
}

export interface StripePayment {
  id: string;
  amount: number;
  currency: string;
  description?: string;
  createdAt: string;
  status: string;
}

export interface CalcomBooking {
  id: number;
  title: string;
  startTime: string;
  endTime: string;
  status: string;
  attendeeName?: string;
  attendeeEmail?: string;
  attendeeNotes?: string;
}

export interface NotionPage {
  id: string;
  title: string;
  emoji?: string;
  lastEditedAt: string;
  url: string;
}

const STORAGE_KEYS = {
  soundEnabled: "coucou.soundEnabled",
  soundVolume: "coucou.soundVolume",
  autoCloseInterval: "coucou.autoCloseInterval",
  activeIntegrations: "coucou.activeIntegrations",
} as const;

export const INTEGRATION_AGENTS: AgentTask[] = [
  {
    id: "integration_claude",
    name: "VS Code",
    color: "#F5F6F8",
    state: "idle",
    stepIndex: 0,
    steps: [],
    source: "claudeCode",
    isIntegration: true,
  },
  {
    id: "integration_resend",
    name: "Resend",
    color: "#22C55E",
    state: "idle",
    stepIndex: 0,
    steps: [],
    source: "n8n",
    isIntegration: true,
  },
  {
    id: "integration_n8n",
    name: "n8n",
    color: "#F29B38",
    state: "idle",
    stepIndex: 0,
    steps: [],
    source: "n8n",
    isIntegration: true,
  },
  {
    id: "integration_vercel",
    name: "Vercel",
    color: "#7C5CFF",
    state: "idle",
    stepIndex: 0,
    steps: [],
    source: "n8n",
    isIntegration: true,
  },
  {
    id: "integration_github",
    name: "GitHub",
    color: "#F4505E",
    state: "idle",
    stepIndex: 0,
    steps: [],
    source: "n8n",
    isIntegration: true,
  },
  {
    id: "integration_notion",
    name: "Notion",
    color: "#8C8C8C",
    state: "idle",
    stepIndex: 0,
    steps: [],
    source: "n8n",
    isIntegration: true,
  },
  {
    id: "integration_calcom",
    name: "Cal.com",
    color: "#C9956A",
    state: "idle",
    stepIndex: 0,
    steps: [],
    source: "n8n",
    isIntegration: true,
  },
  {
    id: "integration_stripe",
    name: "Stripe",
    color: "#0570DE",
    state: "idle",
    stepIndex: 0,
    steps: [],
    source: "n8n",
    isIntegration: true,
  },
];

export const TOGGLEABLE_INTEGRATION_IDS = [
  "integration_resend",
  "integration_n8n",
  "integration_vercel",
  "integration_github",
  "integration_notion",
  "integration_calcom",
  "integration_stripe",
] as const;

type Subscriber = (state: AppState) => void;

function loadBool(key: string, fallback: boolean): boolean {
  try {
    const v = localStorage.getItem(key);
    if (v === null) return fallback;
    return v === "true";
  } catch {
    return fallback;
  }
}

function loadNumber(key: string, fallback: number): number {
  try {
    const v = localStorage.getItem(key);
    if (v === null) return fallback;
    const n = Number(v);
    return Number.isFinite(n) ? n : fallback;
  } catch {
    return fallback;
  }
}

function loadStringSet(key: string, fallback: string[]): Set<string> {
  try {
    const v = localStorage.getItem(key);
    if (!v) return new Set(fallback);
    const parsed = JSON.parse(v) as unknown;
    if (!Array.isArray(parsed)) return new Set(fallback);
    return new Set(parsed.filter((x): x is string => typeof x === "string"));
  } catch {
    return new Set(fallback);
  }
}

function persist(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* private mode / unavailable */
  }
}

let messageId = 0;
function nextChatId(): string {
  messageId += 1;
  return `chat-${messageId}`;
}

export class AppState {
  mode: IslandMode = "hidden";
  view: IslandView = "overview";

  tasks: AgentTask[] = [];
  focusId: string | null = null;

  stateOverride: BotState | null = null;

  soundEnabled = true;
  soundVolume = 0.12;
  autoCloseInterval = 15;

  isPinned = false;
  isPresent = true;

  pendingApproval: ApprovalInfo | null = null;
  alwaysAllow = false;

  chatHistory: ChatMessage[] = [];
  promptContext: PromptContext | null = null;
  droppedFile: DroppedFile | null = null;
  uploadProgress = 0;
  fileDragOver = false;

  vercelProjectFilter = new Set<string>();
  n8nWorkflowFilter = new Set<string>();
  activeIntegrations = loadStringSet(STORAGE_KEYS.activeIntegrations, [
    "integration_resend",
    "integration_n8n",
    "integration_vercel",
    "integration_github",
  ]);

  searchResult: SearchResult | null = null;
  vercelDeployments: VercelDeployment[] = [];
  resendEmails: ResendEmail[] = [];
  resendTotal: number | null = null;
  githubStats: GitHubStats | null = null;
  stripePayments: StripePayment[] = [];
  stripeBalance = 0;
  stripeDisplayBalance = 0;
  stripeCurrency = "eur";
  stripeLoaded = false;
  stripeError: string | null = null;
  calcomBookings: CalcomBooking[] = [];
  calcomLoaded = false;
  calcomError: string | null = null;
  notionPages: NotionPage[] = [];
  notionLoaded = false;
  notionError: string | null = null;

  private subscribers = new Set<Subscriber>();

  constructor() {
    this.soundEnabled = loadBool(STORAGE_KEYS.soundEnabled, true);
    this.soundVolume = loadNumber(STORAGE_KEYS.soundVolume, 0.12);
    const storedAuto = loadNumber(STORAGE_KEYS.autoCloseInterval, 15);
    this.autoCloseInterval = storedAuto === 60 ? 15 : storedAuto;
    this.loadIntegrationTasks();
  }

  get focusTask(): AgentTask | undefined {
    if (this.focusId) {
      return this.tasks.find((t) => t.id === this.focusId) ?? this.tasks[0];
    }
    return this.tasks[0];
  }

  get effectiveState(): BotState {
    return this.stateOverride ?? this.focusTask?.state ?? "idle";
  }

  subscribe(fn: Subscriber): () => void {
    this.subscribers.add(fn);
    return () => this.subscribers.delete(fn);
  }

  private emit(): void {
    for (const fn of this.subscribers) {
      fn(this);
    }
  }

  setMode(mode: IslandMode): void {
    if (this.mode === mode) return;
    this.mode = mode;
    this.emit();
  }

  setView(view: IslandView): void {
    if (this.view === view) return;
    this.view = view;
    this.emit();
  }

  setSoundEnabled(enabled: boolean): void {
    this.soundEnabled = enabled;
    persist(STORAGE_KEYS.soundEnabled, String(enabled));
    this.emit();
  }

  setSoundVolume(volume: number): void {
    this.soundVolume = volume;
    persist(STORAGE_KEYS.soundVolume, String(volume));
    this.emit();
  }

  setAutoCloseInterval(seconds: number): void {
    this.autoCloseInterval = seconds;
    persist(STORAGE_KEYS.autoCloseInterval, String(seconds));
    this.emit();
  }

  setActiveIntegrations(ids: Set<string>): void {
    this.activeIntegrations = ids;
    persist(STORAGE_KEYS.activeIntegrations, JSON.stringify([...ids]));
    this.emit();
  }

  addTask(task: AgentTask): void {
    if (this.tasks.some((t) => t.id === task.id)) return;
    this.tasks = [...this.tasks, task];
    if (this.focusId === null) this.focusId = task.id;
    this.syncMode();
    this.syncView();
    this.emit();
  }

  removeTask(id: string): void {
    this.tasks = this.tasks.filter((t) => t.id !== id);
    if (this.focusId === id) {
      this.focusId = this.tasks[0]?.id ?? null;
    }
    this.syncMode();
    this.syncView();
    this.emit();
  }

  updateTask(id: string, state: BotState): void {
    const idx = this.tasks.findIndex((t) => t.id === id);
    if (idx < 0) return;
    const next = [...this.tasks];
    next[idx] = { ...next[idx], state };
    this.tasks = next;
    this.emit();
  }

  patchTask(id: string, patch: Partial<AgentTask>): void {
    const idx = this.tasks.findIndex((t) => t.id === id);
    if (idx < 0) return;
    const next = [...this.tasks];
    next[idx] = { ...next[idx], ...patch };
    this.tasks = next;
    this.emit();
  }

  setFocus(id: string): void {
    const idx = this.tasks.findIndex((t) => t.id === id);
    if (idx < 0) return;
    this.focusId = id;
    const next = [...this.tasks];
    next[idx] = { ...next[idx], pillBadge: undefined };
    this.tasks = next;
    this.emit();
  }

  appendChat(role: ChatRole, content: string): void {
    this.chatHistory = [
      ...this.chatHistory,
      { id: nextChatId(), role, content },
    ];
    this.emit();
  }

  syncMode(): void {
    let changed = false;
    if (this.tasks.length === 0 && this.mode === "compact") {
      this.mode = "hidden";
      changed = true;
    } else if (
      this.tasks.length > 0 &&
      this.mode === "hidden" &&
      this.isPresent
    ) {
      this.mode = "compact";
      changed = true;
    }
    if (changed) this.emit();
  }

  syncView(): void {
    if (this.mode !== "expanded") return;
    let next = this.view;
    if (this.view === "empty" && this.tasks.length > 0) {
      next = "overview";
    } else if (this.view === "overview" && this.tasks.length === 0) {
      next = "empty";
    }
    if (next !== this.view) {
      this.view = next;
      this.emit();
    }
  }

  loadIntegrationTasks(): void {
    let tasks = [...this.tasks];
    for (const task of INTEGRATION_AGENTS) {
      const shouldLoad =
        task.id === "integration_claude" ||
        this.activeIntegrations.has(task.id);
      const loaded = tasks.some((t) => t.id === task.id);
      if (shouldLoad && !loaded) {
        tasks = [...tasks, { ...task }];
      }
      if (!shouldLoad && loaded) {
        tasks = tasks.filter((t) => t.id !== task.id);
      }
    }
    this.tasks = tasks;
    if (this.focusId === null) {
      this.focusId = "integration_claude";
    }
    this.syncMode();
    this.emit();
  }

  toggleIntegration(id: string): void {
    if (id === "integration_claude") return;
    const nextActive = new Set(this.activeIntegrations);
    if (nextActive.has(id)) {
      nextActive.delete(id);
      this.activeIntegrations = nextActive;
      persist(STORAGE_KEYS.activeIntegrations, JSON.stringify([...nextActive]));
      this.tasks = this.tasks.filter((t) => t.id !== id);
      if (this.focusId === id) this.focusId = "integration_claude";
    } else {
      if (nextActive.size >= 4) return;
      nextActive.add(id);
      this.activeIntegrations = nextActive;
      persist(STORAGE_KEYS.activeIntegrations, JSON.stringify([...nextActive]));
      const agent = INTEGRATION_AGENTS.find((t) => t.id === id);
      if (agent && !this.tasks.some((t) => t.id === id)) {
        this.tasks = [...this.tasks, { ...agent }];
      }
    }
    this.syncMode();
    this.emit();
  }

  setPillBadge(id: string, badge: PillBadge | undefined): void {
    this.patchTask(id, { pillBadge: badge });
  }
}

export const appState = new AppState();

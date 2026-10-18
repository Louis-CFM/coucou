// The Coucou window: a sidebar with Flow (dictation, the Notetaker, the
// statistics, the dictionary, the snippets, the styles and their settings)
// and Notch (every setting of the island), and the page on the right, under
// its coloured band. Port of FlowHub.swift.

import "./hub.css";
import { h, clear } from "../views/dom";
import { t } from "../i18n/i18n";
import { onEvent } from "../core/bridge";
import { FlowBridge, type FlowPrefs, type FlowStatus, type ModelsStatus } from "../core/flow";
import { hero, liveMochi } from "./hero";
import { icon, keyLabel } from "./ui";

export type PageId =
  | "dictation" | "notes" | "insights" | "dictionary" | "snippets" | "styles" | "flowsettings"
  | "general" | "pills" | "agents" | "chat" | "voice" | "integrations" | "phone" | "shortcuts";

interface PageDef {
  id: PageId;
  icon: string;
  title: () => string;
  /** The band's line; none for pages that draw their own band. */
  subtitle?: () => string;
}

export const FLOW_PAGES: PageDef[] = [
  { id: "dictation", icon: "mic", title: () => t("Dictation") },
  { id: "notes", icon: "record", title: () => t("Notetaker") },
  { id: "insights", icon: "chart", title: () => t("Statistics") },
  { id: "dictionary", icon: "book", title: () => t("Dictionary") },
  { id: "snippets", icon: "bolt", title: () => t("Snippets") },
  { id: "styles", icon: "text", title: () => t("Styles") },
  { id: "flowsettings", icon: "sliders", title: () => t("Settings") },
];

export const NOTCH_PAGES: PageDef[] = [
  { id: "general", icon: "gear", title: () => t("General"), subtitle: () => t("Mochi, his sounds and how the island behaves.") },
  { id: "pills", icon: "grid", title: () => t("Active pills"), subtitle: () => t("The pills shown in the island, their order and their colours.") },
  { id: "agents", icon: "terminal", title: () => t("Agents"), subtitle: () => t("Claude Code, Codex and the other agents Mochi follows.") },
  { id: "chat", icon: "chat", title: () => t("Chat"), subtitle: () => t("The AI of the island's chat, with your own keys.") },
  { id: "voice", icon: "wave", title: () => "OK Coucou" },
  { id: "integrations", icon: "puzzle", title: () => t("Integrations"), subtitle: () => t("Stripe, GitHub, Vercel, n8n, Notion and the rest.") },
  { id: "phone", icon: "phone", title: () => t("Android phone"), subtitle: () => t("Your agents and their approvals on your Android phone, over your Wi-Fi.") },
  { id: "shortcuts", icon: "keyboard", title: () => t("Shortcuts"), subtitle: () => t("The keys that open the island and its actions.") },
];

const ALL = [...FLOW_PAGES, ...NOTCH_PAGES];

/** What a page gets to draw itself and reach the rest of the window. */
export interface HubContext {
  status: FlowStatus;
  navigate(page: PageId): void;
  /** Reads the status again (prefs, models) and redraws the sidebar's line. */
  refresh(): Promise<FlowStatus>;
  /** Saves new preferences and keeps them as the window's. */
  setPrefs(change: (p: FlowPrefs) => void): Promise<void>;
  /** The band of a page, its Mochis walking. */
  hero(page: PageId, title: string, subtitle: string | null, actions?: HTMLElement[], compact?: boolean): HTMLElement;
  /** Set by a page: called when the page is left. */
  onLeave?: () => void;
}

export type FlowPageRenderer = (container: HTMLElement, ctx: HubContext) => void | Promise<void>;

export interface HubOptions {
  version: string;
  flowPages: Partial<Record<PageId, FlowPageRenderer>>;
  /** Draws the island's settings for one of the Notch pages into `container`. */
  renderNotch(page: PageId, container: HTMLElement): Promise<void>;
}

const DEFAULT_STATUS: FlowStatus = {
  prefs: {
    enabled: false, key: "right_ctrl", edge: "bottom", mic: "", keepDays: 30, cleanup: false,
    defaultStyle: "natural", summaryEngine: "claude", openAtLaunch: true, voice: false, voiceOutput: "system", voiceGender: "female",
  },
  models: { parakeet: { state: "missing" }, downloadMb: 700 },
  keys: "ok",
  hasClaudeKey: false,
  mics: [],
  platform: navigator.userAgent.includes("Windows") ? "windows" : "linux",
  autostarted: false,
};

export async function startHub(root: HTMLElement, opts: HubOptions) {
  document.body.classList.add("hub-window");
  let current: PageId = "dictation";
  let status: FlowStatus = (await FlowBridge.status()) ?? DEFAULT_STATUS;
  const items = new Map<PageId, HTMLElement>();
  const statusLine = h("div", { class: "hub-status" });
  const scroll = h("div", { class: "hub-scroll" });
  let rendering = 0;

  const ctx: HubContext = {
    get status() {
      return status;
    },
    navigate: (page) => void show(page),
    refresh: async () => {
      status = (await FlowBridge.status()) ?? status;
      drawStatus();
      return status;
    },
    setPrefs: async (change) => {
      const next = { ...status.prefs };
      change(next);
      status = { ...status, prefs: next };
      drawStatus();
      await FlowBridge.setPrefs(next);
    },
    hero: (page, title, subtitle, actions = [], compact = false) => hero(page, title, subtitle, actions, compact),
  };

  function drawStatus() {
    clear(statusLine);
    const models = status.models.parakeet.state;
    let color = "#6b7079";
    let text: string;
    if (!status.prefs.enabled) {
      text = t("Dictation is off");
    } else if (models !== "ready") {
      color = "#f7b32b";
      text = models === "downloading" ? t("Downloading the voice model…") : t("Download the voice model to dictate");
    } else if (status.keys !== "ok" && status.keys !== "wayland") {
      color = "#f7b32b";
      text = t("Use the pill's microphone to dictate");
    } else {
      color = "#34d399";
      text = t("Ready · hold {0}", { 0: keyLabel(status.keys === "wayland" ? "wayland" : status.prefs.key, status.platform) });
    }
    statusLine.append(h("i", { class: "dot", style: `background:${color}` }), h("span", { text }));
  }

  async function show(page: PageId) {
    const def = ALL.find((p) => p.id === page) ?? FLOW_PAGES[0];
    ctx.onLeave?.();
    ctx.onLeave = undefined;
    current = def.id;
    for (const [id, el] of items) el.classList.toggle("on", id === current);
    const token = ++rendering;
    const page_ = h("div", { class: "hub-page" });
    const renderer = opts.flowPages[def.id];
    if (renderer) {
      await renderer(page_, ctx);
    } else {
      page_.append(hero(def.id, def.title(), def.subtitle?.() ?? null));
      const container = h("div", { id: "settings-root" });
      page_.append(container);
      await opts.renderNotch(def.id, container);
    }
    if (token !== rendering) return;
    clear(scroll);
    scroll.append(page_);
    scroll.scrollTop = 0;
  }

  // ── The sidebar ──
  const side = h("nav", { class: "hub-side" });
  const logo = h("canvas", {});
  side.append(h("div", { class: "hub-brand" }, logo, h("span", { text: "Coucou" })));
  liveMochi(logo as HTMLCanvasElement);
  const group = (title: string, pages: PageDef[]) => {
    side.append(h("div", { class: "hub-group", text: title }));
    for (const p of pages) {
      const b = h("button", { class: "hub-item", onclick: () => void show(p.id) });
      b.append(icon(p.icon), h("span", { text: p.title() }));
      items.set(p.id, b);
      side.append(b);
    }
  };
  group("Flow", FLOW_PAGES);
  group(t("Notch"), NOTCH_PAGES);
  side.append(h("div", { class: "spacer" }), statusLine, h("div", { class: "hub-version", text: `Coucou ${opts.version}` }));

  clear(root);
  root.append(side, h("main", { class: "hub-panel" }, scroll));
  drawStatus();
  await show(current);

  void onEvent<string>("hub-page", (page) => {
    const id = (page === "settings" ? "flowsettings" : page) as PageId;
    if (ALL.some((p) => p.id === id)) void show(id);
  });
  void onEvent<FlowPrefs>("flow-prefs", (prefs) => {
    status = { ...status, prefs };
    drawStatus();
  });
  void onEvent<ModelsStatus>("speech-models", (models) => {
    status = { ...status, models };
    drawStatus();
  });
  return {
    redraw: () => void show(current),
    current: () => current,
  };
}

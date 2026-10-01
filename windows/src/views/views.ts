// Island views — DOM ports of IslandViewContent.swift. Paddings, font sizes,
// colours and wording are copied from the Swift views so both platforms read
// identically.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { Ticker } from "./ticker";
import { fileName, hasFilePreview, highlightLine } from "../core/liveChange";
import { State, type AgentTask } from "../core/state";
import { washRGBA, type IslandViewName, type Wash } from "../core/layout";
import { createMiniBot, pruneMiniBots } from "../mochi/minibots";
import { buildPrompt } from "./chat";
import { buildChoose, buildUpload, buildUploading } from "./upload";
import { renderIntegrationCard, type IntegrationCardHooks } from "./integrations";

export interface ViewActions {
  setView(v: IslandViewName): void;
  collapse(): void;
  setFocus(id: string): void;
  openTerminal(): void;
  /** The ↗ button: opens whatever the focused pill points at. */
  openTarget(): void;
  openUrl(url: string): void;
  decide(d: "allow" | "deny"): void;
  toggleSound(): void;
  setVolume(v: number): void;
  setAutoClose(seconds: number): void;
  openSettingsWindow(): void;
  blip(): void;
  /** Hides Alfred completely. Only offered when that is set to the close button. */
  dismiss(): void;
}

export interface ViewHost {
  el: HTMLElement;
  sync(): void;
  /** Called when the view becomes active, for views with a text field. */
  focus?(): void;
  /** Called every frame while the view is on screen. */
  tick?(nowMs: number): void;
}

// ── Shared pieces ─────────────────────────────────────────────────────────────

function card(wash: Wash, ...children: (Node | string)[]): HTMLElement {
  const el = h("div", { class: wash ? "card wash" : "card" }, ...children);
  if (wash) el.style.setProperty("--wash", washRGBA(wash));
  return el;
}

function btn(
  label: string,
  kind: "primary" | "secondary",
  onClick: () => void,
  kbd?: string,
): HTMLElement {
  return h(
    "button",
    { class: `btn ${kind}`, onclick: onClick },
    h("span", { text: label }),
    kbd ? h("span", { class: "kbd", text: kbd }) : null,
  );
}

/** AgentWho — coloured dot + task name + grey label. */
function agentWho(task: AgentTask | null, label: string): HTMLElement {
  const row = h("div", { class: "who-row" });
  if (task) {
    row.append(dot(task.color, 8), h("span", { class: "n", text: task.name }));
  }
  row.append(h("span", { text: label }));
  return row;
}

function stack(padLeft: number, padRight: number, ...children: Node[]): HTMLElement {
  const el = h("div", { class: "stack" }, ...children);
  el.style.padding = `4px ${padRight}px 4px ${padLeft}px`;
  return el;
}

// ── Header ────────────────────────────────────────────────────────────────────

export function buildHeader(actions: ViewActions): ViewHost {
  const tabHome = h("button", { class: "tab", title: "Overview", onclick: () => go("overview") }, svg(ICONS.house, 13));
  const tabChat = h("button", { class: "tab", title: "Ask", onclick: () => go("prompt") }, svg(ICONS.bubble, 13));
  const tabDrop = h("button", { class: "tab", title: "Drop", onclick: () => go("upload") }, svg(ICONS.plus, 13));

  const gearBtn = h("button", { title: "Settings", onclick: () => go("settings") }, svg(ICONS.gear, 14));
  const soundBtn = h("button", { title: "Mute", onclick: () => actions.toggleSound() }, svg(ICONS.speakerOn, 14));
  const hideBtn = h(
    "button",
    { title: "Hide Alfred", hidden: true, onclick: () => actions.dismiss() },
    svg(ICONS.xmark, 12),
  );

  function go(v: IslandViewName) {
    actions.blip();
    actions.setView(v);
  }

  const el = h(
    "div",
    { id: "header" },
    h("div", { class: "tabs" }, tabHome, tabChat, tabDrop),
    h("div", { class: "header-actions" }, gearBtn, soundBtn, hideBtn),
  );

  return {
    el,
    sync() {
      const v = State.view;
      tabHome.classList.toggle("on", v === "overview" || v === "empty" || v === "diff");
      tabChat.classList.toggle("on", v === "prompt");
      tabDrop.classList.toggle("on", v === "upload");
      gearBtn.classList.toggle("on", v === "settings");
      clear(gearBtn);
      gearBtn.append(svg(v === "settings" ? ICONS.gearFill : ICONS.gear, 14));
      clear(soundBtn);
      soundBtn.append(svg(State.settings.soundEnabled ? ICONS.speakerOn : ICONS.speakerOff, 14));
      hideBtn.hidden = State.settings.hideMode !== "manual";
      el.style.opacity = v === "confused" ? "0" : "1";
    },
  };
}

// ── Overview ──────────────────────────────────────────────────────────────────

function buildOverview(actions: ViewActions): ViewHost {
  const ticker = new Ticker();
  const who = h("div", { class: "who" });
  const tickerBody = h("div", { class: "card-body" }, who, ticker.el);
  const leftBody = h("div", { class: "left-body" });
  const jump = h(
    "button",
    { class: "icon-btn jump", title: "Open", onclick: () => actions.openTarget() },
    svg(ICONS.arrowUpRight, 8),
  );
  const left = card(null, leftBody, jump);
  const liveFile = h("div", { class: "live-file" });
  const liveCode = h("div", { class: "live-code" });
  const liveBody = h(
    "button",
    { class: "live", title: "Open the diff", onclick: () => actions.setView("diff") },
    liveFile,
    liveCode,
  );
  const pills = h("div", { class: "pills" });
  const right = card(null, pills);

  const el = h("div", { class: "view overview" },
    h("div", { class: "left" }, left),
    h("div", { class: "right" }, right),
  );

  let pillIds = "";
  let detailOpen = false;
  let lastFocus: string | null = null;
  let mode: "ticker" | "card" | "live" | null = null;
  let cardKey = "";
  let liveKey = "";

  const hooks: IntegrationCardHooks = {
    get detailOpen() {
      return detailOpen;
    },
    openDetail() {
      detailOpen = true;
      cardKey = "";
      State.notify();
    },
    closeDetail() {
      detailOpen = false;
      cardKey = "";
      State.notify();
    },
    openSettings: () => actions.openSettingsWindow(),
  };

  return {
    el,
    tick(nowMs: number) {
      if (mode === "ticker") ticker.tick(nowMs);
    },
    sync() {
      const task = State.focusTask;
      if (task?.id !== lastFocus) {
        lastFocus = task?.id ?? null;
        detailOpen = false;
        cardKey = "";
        mode = null;
      }

      // A running Claude Code or Cursor session keeps the ticker. Once the run
      // is finished, leftover steps ("Recherche · windows") are not a session
      // anymore — an idle pill goes back to its card, unless Cursor just edited
      // a file, in which case that snippet stays clickable.
      const busy =
        task?.state === "working" || task?.state === "thinking" || task?.state === "searching";
      const sessionActive =
        !!task &&
        busy &&
        (task.id === "integration_claude" || task.id === "integration_cursor");
      const change = State.cursorChange;
      const showLive = task?.id === "integration_cursor" && hasFilePreview(change) && !detailOpen;

      if (task && showLive && change) {
        if (mode !== "live") {
          clear(leftBody);
          leftBody.append(liveBody);
          mode = "live";
          cardKey = "";
        }
        const key = `${change.path}\n${change.preview.join("\n")}`;
        if (key !== liveKey) {
          liveKey = key;
          liveFile.textContent = fileName(change.path);
          fillHighlighted(liveCode, change.preview);
        }
      } else if (task && sessionActive) {
        if (mode !== "ticker") {
          clear(leftBody);
          leftBody.append(tickerBody);
          mode = "ticker";
          cardKey = "";
        }
        clear(who);
        who.append(
          dot(task.color, 7),
          h("span", { class: "name", text: task.name }),
          h("span", { class: "tool", text: sourceLabel(task.source) }),
        );
        if (task.steps.length > 1) {
          who.append(h("span", {
            class: "count",
            text: `${Math.min(task.stepIndex + 1, task.steps.length)}/${task.steps.length}`,
          }));
        }
        ticker.sync(task);
        liveKey = "";
      } else if (task) {
        liveKey = "";
        const info = State.integrations[task.id];
        const key = [
          task.id, detailOpen, task.state, task.steps.join("|"),
          info?.loaded, info?.error, info?.configured,
          JSON.stringify(info?.data ?? {}),
        ].join("~");
        if (key !== cardKey) {
          cardKey = key;
          mode = "card";
          clear(leftBody);
          leftBody.append(renderIntegrationCard(task, hooks));
        }
      }

      jump.style.display = detailOpen ? "none" : "";

      const others = State.otherTasks.slice(0, 4);
      const pillKey = others.map((t) => `${t.id}:${t.pillBadge ?? ""}`).join("|");
      if (pillKey !== pillIds) {
        pillIds = pillKey;
        clear(pills);
        for (const t of others) pills.append(buildPill(t, actions));
        pruneMiniBots();
      }
    },
  };
}

function fillHighlighted(host: HTMLElement, lines: string[]) {
  clear(host);
  for (const line of lines) {
    const row = h("div", { class: "live-line" });
    for (const tok of highlightLine(line.length > 0 ? line : " ")) {
      const span = h("span", { text: tok.text });
      if (tok.kind) span.className = `tok-${tok.kind}`;
      row.append(span);
    }
    host.append(row);
  }
}

/** Tool steps are not a summary. "Recherche · windows" means the run grepped, not that it is still searching. */
const TOOL_STEP =
  /^(Exécute|Lit|Écrit|Modifie|Supprime|Cherche|Recherche|Récupère|Tâches|Agent|Notebook|Liste) · |^(⚠|\+|•)/;

function finishedHeadline(task: AgentTask | null): string {
  const last = task?.steps.at(-1);
  if (!last || TOOL_STEP.test(last)) return "Session finished";
  return last;
}

function sourceLabel(source: AgentTask["source"]): string {
  if (source === "claudeCode") return "Claude Code";
  if (source === "cursor") return "Cursor";
  return "n8n";
}

function pillLabel(task: AgentTask): string {
  if (task.id === "integration_claude") return "VS Code";
  if (task.id === "integration_cursor") return "Cursor";
  return task.name;
}

function buildPill(task: AgentTask, actions: ViewActions): HTMLElement {
  const label = pillLabel(task);
  const canvas = createMiniBot(task, 24);
  const pill = h(
    "div",
    { class: "pill", onclick: () => actions.setFocus(task.id) },
    canvas,
    h("span", { class: "lbl", text: label }),
  );
  pill.style.borderColor = `${task.color}24`;
  pill.addEventListener("mouseenter", () => {
    pill.style.background = `${task.color}2e`;
    pill.style.borderColor = `${task.color}8c`;
    pill.style.boxShadow = `0 2px 10px ${task.color}59`;
    (pill.querySelector(".lbl") as HTMLElement).style.color = lighten(task.color, 0.3);
  });
  pill.addEventListener("mouseleave", () => {
    pill.style.background = "";
    pill.style.borderColor = `${task.color}24`;
    pill.style.boxShadow = "";
    (pill.querySelector(".lbl") as HTMLElement).style.color = "";
  });

  if (task.pillBadge) {
    const colors = { approval: "#F5A524", finished: "#22C55E", error: "#F4505E" } as const;
    const icons = { approval: ICONS.bang, finished: ICONS.check, error: ICONS.xmark } as const;
    const inner = h("i", { style: `background:${colors[task.pillBadge]}` }, svg(icons[task.pillBadge], 6, { stroke: task.pillBadge === "finished" ? 3 : 0 }));
    const badge = h("div", { class: "pill-badge" }, inner);
    badge.style.boxShadow = `0 0 4px ${colors[task.pillBadge]}99`;
    pill.append(badge);
  }
  return pill;
}

function lighten(hex: string, amount: number): string {
  const v = parseInt(hex.replace("#", ""), 16);
  const c = [(v >> 16) & 255, (v >> 8) & 255, v & 255].map((x) =>
    Math.min(255, Math.round(x + amount * 255)),
  );
  return `rgb(${c[0]},${c[1]},${c[2]})`;
}

// ── Empty ─────────────────────────────────────────────────────────────────────

function buildEmpty(actions: ViewActions): ViewHost {
  const body = h(
    "div",
    { class: "stack", style: "padding:0 18px 0 118px;flex-direction:row;align-items:center;gap:16px" },
    h(
      "div",
      { style: "display:flex;flex-direction:column;gap:5px" },
      h("div", { class: "title", text: "Nothing running right now." }),
      h("div", { class: "sub", text: "Drop a file or window, or ask me anything." }),
    ),
    h("div", { class: "grow" }),
    btn("Ask Claude", "primary", () => actions.setView("prompt")),
  );
  return { el: h("div", { class: "view" }, card(null, body)), sync() {} };
}

// ── Approval ──────────────────────────────────────────────────────────────────

/** Path and command stay one line. A file edit shows the changed lines instead. */
function paintApproval(code: HTMLElement) {
  clear(code);
  const pending = State.pendingApproval;
  const preview = pending?.preview;
  if (preview && preview.length > 0) {
    code.classList.add("snippet");
    if (pending.file) code.append(h("div", { class: "live-line file", text: pending.file }));
    const host = h("div");
    fillHighlighted(host, preview);
    code.append(host);
    return;
  }
  code.classList.remove("snippet");
  // The whole point of approving here rather than in the terminal: this line
  // is the command, the file path or the URL being authorised, not just the
  // name of the tool asking.
  code.textContent = pending?.command || pending?.tool || "…";
}

function buildApproval(actions: ViewActions): ViewHost {
  const who = h("div");
  const code = h("div", { class: "code" });
  const row = h("div", { class: "actions" });
  const el = h("div", { class: "view" }, card("amber", stack(116, 16, who, code, row)));
  let rowKey = "";
  return {
    el,
    sync() {
      clear(who);
      const owner = State.tasks.find((t) => t.id === State.pendingApproval?.taskId) ?? State.focusTask;
      who.append(agentWho(owner, "needs permission"));
      paintApproval(code);
      // Two buttons, built once. Rebuilding them between a mouse-down and a
      // mouse-up would swallow the click, and there is nothing left to vary:
      // "Always" is gone until the remembered-rules list exists to back it.
      if (rowKey === "built") return;
      rowKey = "built";
      clear(row);
      row.append(
        btn("Deny", "secondary", () => actions.decide("deny"), "N"),
        btn("Allow", "primary", () => actions.decide("allow"), "Y"),
      );
    },
  };
}

// ── Question ──────────────────────────────────────────────────────────────────

function buildQuestion(): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title" });
  const row = h("div", { class: "actions" });
  const el = h("div", { class: "view" }, card("cyan", stack(116, 16, who, title, row)));
  return {
    el,
    sync() {
      clear(who);
      who.append(agentWho(State.focusTask, "Claude Code is asking a question"));
      const task = State.focusTask;
      title.textContent = task?.steps.at(-1) ?? "Claude needs an answer.";
      clear(row);
      row.append(h("div", { class: "sub", text: "Answer in your terminal — Alfred can't reply for you yet." }));
    },
  };
}

// ── Error ─────────────────────────────────────────────────────────────────────

function buildError(actions: ViewActions): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title", text: "Workflow stopped." });
  const detail = h("div", { class: "detail" });
  const openBtn = btn("Open in n8n", "secondary", () => {
    if (State.focusTask?.source === "cursor") actions.openTerminal();
    else actions.openUrl("");
  });
  const row = h("div", { class: "actions" },
    btn("Retry", "primary", () => actions.setView(State.defaultView())),
    openBtn,
  );
  const el = h("div", { class: "view" }, card("red", stack(116, 16, who, title, detail, row)));
  return {
    el,
    sync() {
      const task = State.focusTask;
      clear(who);
      who.append(agentWho(task, task ? sourceLabel(task.source) : "Claude Code"));
      title.textContent = task?.source === "n8n" ? "Workflow stopped." : "Session stopped on an error.";
      const openLabel = openBtn.querySelector("span");
      if (openLabel) openLabel.textContent = task?.source === "cursor" ? "Open Cursor" : "Open in n8n";
      detail.textContent = task?.steps.at(-1) ?? "No detail available.";
    },
  };
}

// ── Finished ──────────────────────────────────────────────────────────────────

function buildFinished(actions: ViewActions): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title" });
  const openBtn = btn("Open terminal", "primary", () => actions.openTerminal());
  const row = h("div", { class: "actions" },
    openBtn,
    btn("OK", "secondary", () => actions.collapse()),
  );
  const el = h("div", { class: "view" }, card("green", stack(116, 16, who, title, row)));
  return {
    el,
    sync() {
      const task = State.focusTask;
      const cursor = task?.source === "cursor";
      clear(who);
      who.append(agentWho(task, cursor ? "Cursor finished" : "Claude Code finished"));
      title.textContent = finishedHeadline(task);
      const openLabel = openBtn.querySelector("span");
      if (openLabel) openLabel.textContent = cursor ? "Open Cursor" : "Open terminal";
    },
  };
}

// ── Confused ──────────────────────────────────────────────────────────────────

function buildConfused(): ViewHost {
  const body = h(
    "div",
    { class: "stack", style: "padding:0 18px 0 128px" },
    h("div", { class: "title", text: "Too many hits at once." }),
    h("div", { class: "sub", text: "Give me a sec — back to work in three seconds." }),
  );
  return { el: h("div", { class: "view" }, card("pink", body)), sync() {} };
}

// ── Note ──────────────────────────────────────────────────────────────────────

function buildNote(): ViewHost {
  const title = h("div", { class: "title" });
  const el = h("div", { class: "view" }, card(null, h("div", { class: "stack", style: "padding:0 18px 0 98px" }, title)));
  return {
    el,
    sync() {
      title.textContent = State.noteMessage ?? "";
    },
  };
}

// ── In-island settings ────────────────────────────────────────────────────────

function buildSettings(actions: ViewActions): ViewHost {
  const soundSwitch = h("button", { class: "switch", onclick: () => actions.toggleSound() });
  const volume = h("input", {
    type: "range", min: "0", max: "0.2", step: "0.005",
    oninput: (e: Event) => actions.setVolume(Number((e.target as HTMLInputElement).value)),
  }) as HTMLInputElement;
  const autoLabel = h("span", {});
  const timerIcon = svg(ICONS.timer, 12);
  const segButtons = [10, 15, 30].map((s) =>
    h("button", { onclick: () => actions.setAutoClose(s) }, `${s}s`),
  );
  const seg = h("div", { class: "seg" }, ...segButtons);
  const claudeBadge = h("span", { class: "status-badge" });
  const cursorBadge = h("span", { class: "status-badge" });
  const apiBadge = h("span", { class: "status-badge" });

  const rows = h(
    "div",
    { class: "settings-rows" },
    h("div", { class: "settings-row" }, soundSwitch, h("span", { text: "Sound" }), volume),
    h(
      "div",
      { class: "settings-row" },
      timerIcon,
      autoLabel,
      seg,
    ),
    h(
      "div",
      { class: "settings-row", style: "gap:14px" },
      claudeBadge,
      cursorBadge,
      apiBadge,
      h("div", { class: "grow" }),
      h("button", {
        class: "link-btn",
        style: "color:#8e939c;font-size:11.5px",
        text: "Settings…",
        onclick: () => actions.openSettingsWindow(),
      }),
    ),
  );

  const el = h("div", { class: "view" },
    card(null, h("div", { class: "stack", style: "padding:14px 16px 14px 84px" }, rows)));

  return {
    el,
    sync() {
      const s = State.settings;
      soundSwitch.classList.toggle("on", s.soundEnabled);
      volume.value = String(s.soundVolume);
      volume.style.opacity = s.soundEnabled ? "1" : "0.4";
      const shrinkOutside = s.shrinkMode === "outside";
      autoLabel.textContent = shrinkOutside
        ? "Shrinks on an outside click"
        : `Auto-close · ${Math.round(s.autoCloseInterval)}s`;
      timerIcon.style.display = shrinkOutside ? "none" : "";
      seg.hidden = shrinkOutside;
      segButtons.forEach((b, i) => b.classList.toggle("on", s.autoCloseInterval === [10, 15, 30][i]));
      clear(claudeBadge);
      claudeBadge.append(
        dot(s.hooksInstalled ? "#22C55E" : "#F4505E", 6),
        h("span", { text: "Claude Code" }),
      );
      clear(cursorBadge);
      cursorBadge.append(
        dot(s.cursorHooksInstalled ? "#22C55E" : "#F4505E", 6),
        h("span", { text: "Cursor" }),
      );
      clear(apiBadge);
      apiBadge.append(dot("#F4505E", 6), h("span", { text: "API" }));
    },
  };
}

// ── File diff ─────────────────────────────────────────────────────────────────

function buildDiff(actions: ViewActions): ViewHost {
  const back = h(
    "button",
    { class: "diff-back", title: "Overview", onclick: () => actions.setView("overview") },
    svg(ICONS.chevronLeft, 11, { stroke: 2.4 }),
  );
  const file = h("div", { class: "diff-file" });
  const lines = h("div", { class: "diff-lines" });
  const shell = h("div", { class: "diff-shell" });
  const el = h(
    "div",
    { class: "view diff-view" },
    card(
      null,
      h("div", { class: "diff-pad" }, h("div", { class: "diff-top" }, back, file), lines, shell),
    ),
  );
  let key = "";
  return {
    el,
    sync() {
      const change = State.cursorChange;
      const next = change
        ? `${change.path}\n${change.diff.map((l) => l.kind + l.text).join("\n")}\n${change.command ?? ""}\n${change.output ?? ""}\n${change.ok}`
        : "";
      if (next === key) return;
      key = next;
      clear(lines);
      clear(shell);
      if (!change || !hasFilePreview(change)) {
        file.textContent = "No edit yet";
        lines.append(h("div", { class: "diff-empty", text: "Cursor hasn't modified a file in this run." }));
        shell.style.display = "none";
        return;
      }
      file.textContent = fileName(change.path);
      file.title = change.path;
      for (const line of change.diff) {
        const mark = line.kind === "add" ? "+" : line.kind === "del" ? "−" : " ";
        const text = h("span", { class: "diff-text" });
        for (const tok of highlightLine(line.text.length > 0 ? line.text : " ")) {
          const span = h("span", { text: tok.text });
          if (tok.kind) span.className = `tok-${tok.kind}`;
          text.append(span);
        }
        lines.append(
          h("div", { class: `diff-row ${line.kind}` }, h("span", { class: "diff-mark", text: mark }), text),
        );
      }
      if (!change.command && !change.output) {
        shell.style.display = "none";
        return;
      }
      shell.style.display = "";
      shell.append(h("div", { class: "diff-cmd", text: `$ ${change.command ?? ""}` }));
      if (change.output) {
        shell.append(h("pre", { class: change.ok === false ? "diff-out bad" : "diff-out ok", text: change.output }));
      }
    },
  };
}

// ── Placeholders filled in later stages ───────────────────────────────────────

function buildPlaceholder(title: string, sub: string): ViewHost {
  const body = h(
    "div",
    { class: "stack", style: "padding:0 18px 0 118px" },
    h("div", { class: "title", text: title }),
    h("div", { class: "sub", text: sub }),
  );
  return { el: h("div", { class: "view" }, card(null, body)), sync() {} };
}

// ── Registry ──────────────────────────────────────────────────────────────────

export function buildViews(
  actions: ViewActions,
  onChatHeightChange: () => void,
): Map<IslandViewName, ViewHost> {
  const map = new Map<IslandViewName, ViewHost>();
  map.set("overview", buildOverview(actions));
  map.set("empty", buildEmpty(actions));
  map.set("approval", buildApproval(actions));
  map.set("question", buildQuestion());
  map.set("error", buildError(actions));
  map.set("finished", buildFinished(actions));
  map.set("confused", buildConfused());
  map.set("note", buildNote());
  map.set("settings", buildSettings(actions));
  map.set("prompt", buildPrompt(onChatHeightChange));
  map.set("upload", buildUpload());
  map.set("uploading", buildUploading());
  map.set("choose", buildChoose(actions));
  // Not in the Windows v1: sending a file by email, window attach + web result.
  map.set("mail", buildPlaceholder("Sending by email isn't in this version.", ""));
  map.set("searching", buildPlaceholder("Claude is searching…", ""));
  map.set("result", buildPlaceholder("Result", ""));
  map.set("diff", buildDiff(actions));
  return map;
}

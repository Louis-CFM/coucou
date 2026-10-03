// Island views — DOM ports of IslandViewContent.swift. Paddings, font sizes,
// colours and wording are copied from the Swift views so both platforms read
// identically.

import { h, svg, clear, dot, replay } from "./dom";
import { ICONS } from "./icons";
import { CLAUDE_ID, State, TURN_DONE, turnSteps, type AgentTask, type ClaudeSession, type SessionStep } from "../core/state";
import { CARD_AIR_MIN, VIEW_LAYOUTS, fittedHeight, washRGBA, type BotEmoteName, type BotStateName, type IslandViewName, type Wash } from "../core/layout";
import { createMiniBot, pruneMiniBots } from "../mochi/minibots";
import { buildPrompt } from "./chat";
import { buildChoose, buildUpload, buildUploading } from "./upload";
import { renderIntegrationCard, type GithubOpening, type IntegrationCardHooks } from "./integrations";
import { buildGithub, enterGithubPanel, newsFacts } from "./github";
import { buildSession, sessionName, sessionsChip } from "./session";
import { diffLine, fileKind, plusMinus, readPatch } from "./code";
import { hasPreview, stepIcon, stepName, stepPreview } from "./step";
import { COLOR } from "./palette";
import type { IntegrationNews } from "../core/bridge";

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
  /** Mochi reacts to something a view just showed (the GitHub panel's news). */
  emote(e: BotEmoteName): void;
  /**
   * Mochi's body takes a colour (hex) while the mouse is on something — a day
   * of the GitHub graph. Null gives him his own back.
   */
  tintMochi(color: string | null): void;
  /**
   * The view is showing something Mochi should wear the state of — a run
   * going (working), a run that just ended before your eyes (finished, error),
   * with the entrance the engine plays for that state. It holds for as long
   * as the view asks, unless Mochi's own state says more; null gives it back.
   */
  look(state: BotStateName | null): void;
  /**
   * Into the GitHub panel, on what the news at hand is about. Seen, it is not
   * news any more: the pill goes back to rest. False when there was none.
   */
  followNews(): boolean;
  /** The answers to the question on the card, keyed by each question's own words. */
  answer(answers: Record<string, string>): void;
  /** The question on the card goes unanswered: Claude is told so and carries on without. */
  skipQuestion(): void;
  /** Leaves the question on the card to Claude Code's own window. */
  passQuestion(): void;
  /** A text field wants the keyboard, or gives it back: the island never takes it on its own. */
  keyboard(on: boolean): void;
  /**
   * Into the session panel: what Claude is writing or, its turn over, what it
   * said. With `changes`, straight to the list of files it changed.
   */
  openSession(changes?: boolean): void;
  /** Into the session panel, on the list of the sessions followed: the way from one to another. */
  openSessions(): void;
  /** Puts another Claude Code session in front: the island shows that one. */
  pickSession(id: string): void;
}

/** Lines of a step's preview the overview has room for. */
const NOW_LINES = 3;
/**
 * A session's card holds a line more than the overview was cut for — the
 * step, then three lines of what it did: the island is this much taller for
 * it, so the card keeps the same air under its last line as above its first.
 */
const SESSION_CARD_ROOM = 12;

/** A reply's first line as plain words: what marks it as bold, a heading or code goes. */
function firstWords(text: string | null): string | null {
  return text?.split("\n").find((line) => line.trim())?.replace(/^#{1,6}\s+|\*\*|`/g, "").trim() ?? null;
}

/** A reply as plain words, for a few lines of it: what marks headings, bold, code and lists goes. */
function plainWords(text: string | null): string | null {
  const words = text
    ?.split("\n")
    .map((line) => line.replace(/^\s*(#{1,6}|[-*+]|\d+[.)])\s+|\*\*|`/g, "").trim())
    .filter((line) => line && !/^\|?[\s:|-]+\|?$/.test(line))
    .join(" ");
  return words || null;
}

/**
 * What a session is doing now, in the two lines the overview gives it: the
 * step by its icon and its name with what it is at, and a look at what it did
 * — or, the turn over, "Done" and the first lines of what Claude replied.
 */
interface Now {
  icon: Element;
  label: string;
  detail: string;
  /** The colour the label takes when it says more than a tool's name. */
  color: string | null;
  /** The step whose preview fills the box, or the words that do. */
  step: SessionStep | null;
  words: string | null;
}

function nowOf(session: ClaudeSession): Now {
  const steps = turnSteps(session);
  const last = steps.at(-1) ?? null;
  const shown = [...steps].reverse().find(hasPreview) ?? null;
  const oneLine = (text: string | null) => text?.split("\n")[0] ?? "";

  if (session.question || session.approval) {
    return {
      icon: svg(ICONS.bang, 12), label: "Waiting", color: session.question ? COLOR.cyan : COLOR.amber,
      detail: session.question ? "for your answer" : "for your permission", step: shown, words: null,
    };
  }
  if (session.state === "error") {
    return { icon: svg(ICONS.xmark, 11), label: "Stopped", color: COLOR.red, detail: "on an error", step: shown, words: session.lines.at(-1) ?? null };
  }
  // The turn is over when the journal's last line is Claude's reply — a word
  // from Claude Code after it (a notification that it is waiting, a subagent
  // winding down) does not put the session back to work.
  const ended = [...session.steps].reverse().find((step) => step.kind !== "note")?.tool === TURN_DONE;
  if (ended || session.state === "finished") {
    // What matters then is that Claude is done and has answered: its words
    // take the place of the last thing it ran. With no words, that stays.
    const said = plainWords(session.answer);
    return {
      icon: svg(ICONS.check, 12, { stroke: 3 }), label: "Done", color: COLOR.green,
      detail: said ? "Claude replied" : "", step: said ? null : shown, words: said,
    };
  }
  if (last) {
    return { icon: stepIcon(last), label: stepName(last), color: null, detail: oneLine(last.target), step: hasPreview(last) ? last : shown, words: null };
  }
  if (session.state === "thinking") {
    return { icon: svg(ICONS.bubble, 12), label: "Thinking", color: null, detail: "", step: null, words: session.asked };
  }
  return { icon: svg(ICONS.bubble, 12), label: "Open", color: null, detail: "waiting for a prompt", step: null, words: null };
}


export interface ViewHost {
  el: HTMLElement;
  sync(): void;
  /** Called when the view becomes active, for views with a text field. */
  focus?(): void;
  /** Called every frame while the view is on screen. */
  tick?(nowMs: number): void;
  /** How tall the island should be for what the view holds now, when that varies. */
  readonly height?: number;
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

/**
 * Whose card this is, for a card about a Claude Code session: the conversation
 * by its name — with several open, the project alone would not say which —
 * and, when other sessions are waiting for an answer behind it, how many.
 */
function sessionWho(label: string): HTMLElement {
  const task = State.tasks.find((t) => t.id === CLAUDE_ID) ?? State.focusTask;
  const session = State.session;
  const row = h("div", { class: "who-row" });
  if (task) row.append(dot(task.color, 8), h("span", { class: "n", text: session.id ? sessionName(session) : task.name }));
  row.append(h("span", { text: label }));
  const waiting = State.waiting.length;
  if (waiting > 0) row.append(h("span", { class: "who-waiting", text: `+${waiting} waiting`, title: "Other sessions waiting for an answer" }));
  return row;
}

function stack(padLeft: number, padRight: number, ...children: Node[]): HTMLElement {
  const el = h("div", { class: "stack" }, ...children);
  el.style.padding = `4px ${padRight}px 4px ${padLeft}px`;
  return el;
}

/**
 * Keeps a card whose lines vary from filling up to its edges: measures what
 * its stack holds and asks the island for the height that leaves the least
 * air a card keeps. A card with room to spare is left as tall as it always was.
 */
function airy(lines: HTMLElement, onResize: () => void): { fit(): void; readonly height: number | undefined } {
  let height: number | undefined;
  const fit = () => {
    const parts = [...lines.children].map((child) => (child as HTMLElement).offsetHeight).filter((h) => h > 0);
    const gap = parseFloat(getComputedStyle(lines).rowGap) || 0;
    const content = parts.reduce((sum, part) => sum + part, 0) + gap * Math.max(0, parts.length - 1);
    // Not on screen yet: nothing to measure, the layout's own height stands.
    const next = parts.length > 0 ? fittedHeight(content, CARD_AIR_MIN) : undefined;
    if (next === height) return;
    height = next;
    onResize();
  };
  // Measured again when the card's width changes: while the island is still
  // opening it is narrow, its lines wrap, and it looks taller than it is.
  new ResizeObserver(fit).observe(lines);
  return {
    fit,
    get height() {
      return height;
    },
  };
}

// ── Header ────────────────────────────────────────────────────────────────────

export function buildHeader(actions: ViewActions): ViewHost {
  const tabHome = h("button", { class: "tab", title: "Overview", onclick: () => go("overview") }, svg(ICONS.house, 13));
  const tabChat = h("button", { class: "tab", title: "Ask", onclick: () => go("prompt") }, svg(ICONS.bubble, 13));
  const tabDrop = h("button", { class: "tab", title: "Drop", onclick: () => go("upload") }, svg(ICONS.plus, 13));

  const gearBtn = h("button", { title: "Settings", onclick: () => go("settings") }, svg(ICONS.gear, 14));
  const soundBtn = h("button", { title: "Mute", onclick: () => actions.toggleSound() }, svg(ICONS.speakerOn, 14));

  function go(v: IslandViewName) {
    actions.blip();
    actions.setView(v);
  }

  const el = h(
    "div",
    { id: "header" },
    h("div", { class: "tabs" }, tabHome, tabChat, tabDrop),
    h("div", { class: "header-actions" }, gearBtn, soundBtn),
  );

  return {
    el,
    sync() {
      const v = State.view;
      // The GitHub panel is reached from the overview and goes back to it.
      tabHome.classList.toggle("on", v === "overview" || v === "empty" || v === "github" || v === "session");
      tabChat.classList.toggle("on", v === "prompt");
      tabDrop.classList.toggle("on", v === "upload");
      gearBtn.classList.toggle("on", v === "settings");
      clear(gearBtn);
      gearBtn.append(svg(v === "settings" ? ICONS.gearFill : ICONS.gear, 14));
      clear(soundBtn);
      soundBtn.append(svg(State.settings.soundEnabled ? ICONS.speakerOn : ICONS.speakerOff, 14));
      el.style.opacity = v === "confused" ? "0" : "1";
    },
  };
}

// ── Overview ──────────────────────────────────────────────────────────────────

function buildOverview(actions: ViewActions, onResize: () => void): ViewHost {
  const who = h("div", { class: "who" });
  // What the session is doing: the step, and under it a look at what it did.
  const nowLine = h("div", { class: "now-line" });
  const nowBox = h("div", { class: "now-box" });
  // With several sessions followed: how many, and the way to the list of them.
  const sessionsBtn = sessionsChip(() => {
    actions.blip();
    actions.openSessions();
  });
  const sessionBody = h("div", { class: "card-body sess-card" }, who, nowLine, nowBox);
  const leftBody = h("div", { class: "left-body" });
  const jump = h(
    "button",
    { class: "icon-btn jump", title: "Open", onclick: () => actions.openTarget() },
    svg(ICONS.arrowUpRight, 8),
  );
  const left = card(null, leftBody, jump);
  // A session is its card: a click anywhere on it opens the session panel —
  // the file being written, the steps, the changes. The ↗ stays the way out
  // to where the session runs.
  left.addEventListener("click", (e) => {
    if (mode !== "session" || (e.target as Element).closest("button")) return;
    actions.blip();
    actions.openSession();
  });
  const pills = h("div", { class: "pills" });
  const right = card(null, pills);

  const el = h("div", { class: "view overview" },
    h("div", { class: "left" }, left),
    h("div", { class: "right" }, right),
  );

  let pillIds = "";
  let detailOpen = false;
  let lastFocus: string | null = null;
  let mode: "session" | "card" | null = null;
  let cardKey = "";
  let lineKey = "";
  let boxKey = "";
  /** The mode the island's height was last asked for. */
  let sized: "session" | "card" | null = null;

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
    // The card's figure asks for the panel as a whole: while the pill has
    // news, that leads to what the news is about.
    openPanel: (open) => {
      if (!open && actions.followNews()) return;
      toGithubPanel(actions, open);
    },
  };

  /** The session's two lines, redrawn only when what they show has changed. */
  function syncNow(session: ClaudeSession) {
    const now = nowOf(session);
    const step = now.step;
    // The line and the box each come in when what they show changes — and
    // only then: a step that goes from one file to the next moves the line,
    // not the box still showing the last result.
    const nextLine = [session.id, now.label, now.detail].join("~");
    if (nextLine !== lineKey) {
      lineKey = nextLine;
      clear(nowLine);
      const label = h("b", { text: now.label });
      const icon = h("i", {}, now.icon);
      if (now.color) {
        label.style.color = now.color;
        icon.style.color = now.color;
      }
      nowLine.append(icon, label, h("span", { class: now.color ? "said" : "at", text: now.detail, title: now.detail }));
      replay(nowLine, "now-in");
    }
    const nextBox = [
      session.id, step?.tool, step?.target, step?.at, step?.state,
      step?.result?.text.length, step?.patch?.length, step ? "" : now.words,
    ].join("~");
    if (nextBox === boxKey) return;
    boxKey = nextBox;
    clear(nowBox);
    const preview = step ? stepPreview(step, NOW_LINES) : null;
    if (preview) nowBox.append(preview);
    else if (now.words) nowBox.append(h("div", { class: "now-words", text: now.words.trim() }));
    nowBox.style.display = nowBox.firstChild ? "" : "none";
    if (nowBox.firstElementChild) replay(nowBox.firstElementChild as HTMLElement, "now-in");
  }

  return {
    el,
    get height() {
      return mode === "session" ? VIEW_LAYOUTS.overview.height + SESSION_CARD_ROOM : undefined;
    },
    sync() {
      const task = State.focusTask;
      if (task?.id !== lastFocus) {
        lastFocus = task?.id ?? null;
        detailOpen = false;
        cardKey = "";
        mode = null;
      }

      // The Claude pill with a session to show has the session's card; every
      // other pill shows its own, exactly like IntegrationCardView.
      const session = task?.id === CLAUDE_ID && State.session.id ? State.session : null;

      if (task && session) {
        if (mode !== "session") {
          clear(leftBody);
          leftBody.append(sessionBody);
          mode = "session";
          cardKey = "";
        }
        clear(who);
        who.append(
          dot(task.color, 7),
          // A conversation that has a title goes by it, as it does in Claude
          // Code, with its project after; untitled, the project is its name.
          h("span", { class: "name", text: session.title ?? task.name, title: session.title ?? "" }),
          h("span", { class: "tool", text: session.title ? task.name : "Claude Code" }),
        );
        sessionsBtn.sync();
        who.append(sessionsBtn.el);
        // What the session has written so far: the lines added and removed —
        // when the chip is not there: the title keeps the room, and the panel has them.
        const files = State.sessions.length > 1 ? [] : State.sessionFiles;
        if (files.length > 0) {
          const size = plusMinus(files.reduce((n, f) => n + f.additions, 0), files.reduce((n, f) => n + f.deletions, 0));
          size.classList.add("count");
          size.title = files.length === 1 ? "1 file changed" : `${files.length} files changed`;
          who.append(size);
        }
        syncNow(session);
      } else if (task) {
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
      if (mode !== sized) {
        sized = mode;
        onResize();
      }

      left.classList.toggle("opens", mode === "session");
      left.title = mode === "session" ? "Open the session" : "";

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

function buildPill(task: AgentTask, actions: ViewActions): HTMLElement {
  const label = task.id === CLAUDE_ID ? State.clientName : task.name;
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

function buildApproval(actions: ViewActions, onResize: () => void): ViewHost {
  const who = h("div");
  const code = h("div", { class: "code" });
  // For an edit: the diff it would make, between what is asked and the answer.
  const proposed = h("div", { class: "proposed gh-code" });
  const row = h("div", { class: "actions" });
  const lines = stack(116, 16, who, code, proposed, row);
  const el = h("div", { class: "view" }, card("amber", lines));
  const air = airy(lines, onResize);
  let rowKey = "";
  let proposedKey = "";
  return {
    el,
    // With a diff the island is as tall as the window allows, and the diff takes what is left.
    get height() {
      return State.pendingApproval?.proposal ? undefined : air.height;
    },
    sync() {
      const approval = State.pendingApproval;
      const proposal = approval?.proposal ?? null;
      clear(who);
      const asking = sessionWho("needs permission");
      if (proposal) asking.append(plusMinus(proposal.additions, proposal.deletions));
      who.append(asking);
      // The whole point of approving here rather than in the terminal: this line
      // is the command, the file path or the URL being authorised, not just the
      // name of the tool asking.
      code.textContent = proposal
        ? `${approval?.tool} · ${proposal.path}${proposal.created ? " · new file" : ""}`
        : approval?.command || approval?.tool || "…";
      // What that edit would do, line by line, before it is allowed. Drawn once
      // per request: a list redrawn under the mouse would lose its scroll.
      proposed.style.display = proposal ? "" : "none";
      // A diff takes all the room it is given: the card keeps the air a
      // card has above its first line and under its buttons.
      lines.classList.toggle("airy", proposal != null);
      const nextProposed = proposal ? (approval?.requestId ?? "") : "";
      if (nextProposed !== proposedKey) {
        proposedKey = nextProposed;
        clear(proposed);
        if (proposal) {
          const kind = fileKind(proposal.path);
          const diff = h("div", { class: "gh-diff" });
          for (const line of readPatch(proposal.patch)) {
            if (!("hunk" in line)) diff.append(diffLine(line.new ?? line.old, line.sign, line.text, kind));
          }
          if (proposal.truncated) {
            diff.append(
              h("div", { class: "gh-diff-line hunk" }, h("span", { class: "n", text: "⋯" }), h("span", { class: "s" }), h("span", { class: "t", text: "The rest of this edit is in Claude Code" })),
            );
          }
          proposed.append(diff);
          // Open on the first line that changes, a line of context above it.
          const first = diff.querySelector<HTMLElement>(".add, .del");
          proposed.scrollTop = first ? Math.max(0, first.offsetTop - diff.offsetTop - first.offsetHeight) : 0;
        }
      }
      // Two buttons, built once. Rebuilding them between a mouse-down and a
      // mouse-up would swallow the click, and there is nothing left to vary:
      // "Always" is gone until the remembered-rules list exists to back it.
      if (rowKey !== "built") {
        rowKey = "built";
        clear(row);
        row.append(
          btn("Deny", "secondary", () => actions.decide("deny"), "N"),
          btn("Allow", "primary", () => actions.decide("allow"), "Y"),
        );
      }
      air.fit();
    },
  };
}

// ── Question ──────────────────────────────────────────────────────────────────

/** Several options picked for one question go back as one answer, as Claude Code writes them. */
const ANSWER_JOIN = ", ";
/** A click in the field asks the window for the keyboard; this long later it has it. */
const FOCUS_MS = 120;

/**
 * A question Claude asks with its question tool, answered here: one question
 * at a time, each option with what it means beside it.
 * "Other…" takes a typed answer. The last answer sends them all — and the
 * session, wherever it runs, goes on as if they had been picked there.
 */
function buildQuestion(actions: ViewActions, onResize: () => void): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title q-title" });
  const row = h("div", { class: "actions q-options" });
  const hint = h("span", { class: "q-hint" });
  const back = h("button", { class: "link-btn q-link", text: "‹ Previous" });
  const pass = h("button", { class: "link-btn q-link", onclick: () => actions.passQuestion() });
  const skip = h("button", { class: "btn secondary q-skip", text: "Skip", title: "Leave this question unanswered", onclick: () => actions.skipQuestion() });
  // Under a list of options: "Other…", and Send when several can be picked.
  const tail = h("div", { class: "q-tail" });
  const foot = h("div", { class: "q-foot" }, tail, hint, h("div", { class: "grow" }), back, pass, skip);
  const field = h("input", {
    class: "island-field", type: "text", maxlength: "2000", autocomplete: "off", spellcheck: "false",
    placeholder: "Your answer",
  }) as HTMLInputElement;
  const lines = stack(116, 16, who, title, row, foot);
  // A question with more options than the window is tall for fills its card:
  // the list of options scrolls, and the card keeps its least air around it.
  lines.style.paddingTop = lines.style.paddingBottom = `${CARD_AIR_MIN}px`;
  const el = h("div", { class: "view" }, card("cyan", lines));

  /** The request all of this is about: a new one starts from the first question. */
  let request = "";
  let at = 0;
  /** One answer per question answered so far. */
  let answers: string[] = [];
  /** A question that takes several: the labels picked so far. */
  let picked = new Set<string>();
  let typing = false;
  let key = "";
  /** The island's height for what the card holds now; unset until it has been measured. */
  let height: number | undefined;

  /** Asks the island for the room the card's content takes, no more. */
  function fit() {
    // The card's lines, and the gap the stack leaves between each two of them.
    const parts = [who.offsetHeight, title.offsetHeight, row.scrollHeight, foot.offsetHeight];
    const gap = parseFloat(getComputedStyle(lines).rowGap) || 0;
    const content = parts.reduce((sum, part) => sum + part, 0) + gap * (parts.length - 1);
    // Not on screen yet: nothing to measure, the layout's own height stands.
    const next = who.offsetHeight > 0 ? fittedHeight(content) : undefined;
    if (next === height) return;
    height = next;
    onResize();
  }

  // Measured again whenever the card's width changes: while the island is still
  // opening it is narrow, the lines wrap, and the content looks taller than it is.
  new ResizeObserver(() => fit()).observe(el);

  function settle(value: string) {
    const info = State.pendingQuestion;
    if (!info || !value) return;
    answers[at] = value;
    stopTyping();
    picked = new Set();
    if (at + 1 < info.questions.length) {
      at++;
      actions.blip();
      State.notify();
      return;
    }
    const out: Record<string, string> = {};
    info.questions.forEach((q, i) => (out[q.question] = answers[i] ?? ""));
    actions.answer(out);
  }

  function stopTyping() {
    typing = false;
    field.value = "";
    field.blur();
  }

  field.addEventListener("blur", () => actions.keyboard(false));
  field.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.key === "Enter") settle(field.value.trim());
    else if (e.key === "Escape") {
      stopTyping();
      State.notify();
    }
  });
  back.addEventListener("click", () => {
    if (at === 0) return;
    at--;
    stopTyping();
    picked = new Set();
    actions.blip();
    State.notify();
  });

  function draw() {
    const info = State.pendingQuestion;
    if ((info?.requestId ?? "") !== request) {
      request = info?.requestId ?? "";
      at = 0;
      answers = [];
      picked = new Set();
      typing = false;
      key = "";
    }
    // Rebuilding the buttons between a mouse-down and its mouse-up would
    // swallow the click, so only rebuild when what they show has changed.
    const next = [request, at, typing, [...picked].join("|"), State.clientName, State.waiting.length].join("~");
    if (next === key) return;
    key = next;

    const task = State.tasks.find((t) => t.id === CLAUDE_ID) ?? State.focusTask;
    const q = info?.questions[at];
    clear(who);
    clear(row);
    clear(tail);
    pass.textContent = `Answer in ${State.clientName}`;
    back.style.display = at > 0 ? "" : "none";
    if (!info || !q) {
      who.append(sessionWho("is asking a question"));
      title.textContent = task?.steps.at(-1) ?? "Claude needs an answer.";
      hint.textContent = "";
      pass.style.display = "none";
      skip.style.display = "none";
      return;
    }
    pass.style.display = "";
    skip.style.display = "";

    const asking = sessionWho("is asking a question");
    if (q.header) asking.append(h("span", { class: "q-chip", text: q.header }));
    if (info.questions.length > 1) asking.append(h("span", { class: "q-count", text: `${at + 1}/${info.questions.length}` }));
    who.append(asking);
    title.textContent = q.question;
    title.title = q.question;

    const rest = q.multiSelect ? "Pick one or more, then send." : "";
    hint.textContent = rest;

    if (typing) {
      row.classList.remove("q-list");
      row.append(
        field,
        btn(at + 1 < info.questions.length ? "Next" : "Send", "primary", () => settle(field.value.trim())),
        btn("Back", "secondary", () => {
          stopTyping();
          State.notify();
        }),
      );
      return;
    }

    // Options that explain themselves are read before they are picked: each
    // on a line of its own, what it means beside its name. Bare labels stay
    // the row of buttons of the prototype.
    const explained = q.options.some((o) => o.description);
    row.classList.toggle("q-list", explained);
    for (const option of q.options) {
      const on = picked.has(option.label);
      const el = explained
        ? h(
            "button",
            { class: on ? "q-row on" : "q-row" },
            h("b", { text: option.label }),
            h("span", { text: option.description ?? "", title: option.description ?? "" }),
          )
        : h("button", { class: on ? "btn secondary q-opt on" : "btn secondary q-opt" }, h("span", { text: option.label }));
      el.addEventListener("click", () => {
        if (!q.multiSelect) return settle(option.label);
        if (!picked.delete(option.label)) picked.add(option.label);
        State.notify();
      });
      row.append(el);
    }
    // After the options: in the row of buttons, or under the list, at its foot.
    const after = explained ? tail : row;
    after.append(
      h("button", {
        class: "btn secondary q-opt other",
        text: "Other…",
        onclick: () => {
          typing = true;
          State.notify();
          actions.keyboard(true);
          window.setTimeout(() => field.focus(), FOCUS_MS);
        },
      }),
    );
    if (q.multiSelect) {
      after.append(
        btn(at + 1 < info.questions.length ? "Next" : "Send", "primary", () =>
          // In the order the options are listed, not the order they were clicked.
          settle(q.options.filter((o) => picked.has(o.label)).map((o) => o.label).join(ANSWER_JOIN)),
        ),
      );
    }
  }

  return {
    el,
    get height() {
      return height;
    },
    sync() {
      draw();
      fit();
    },
  };
}

// ── Error ─────────────────────────────────────────────────────────────────────

/** Into the GitHub panel — on its lists, or straight on what `open` is about. */
function toGithubPanel(actions: ViewActions, open?: GithubOpening) {
  actions.blip();
  enterGithubPanel(open);
  actions.setView("github");
}

/** The news of the Mochi at the front, when its integration sent some. */
function frontNews(): IntegrationNews | null {
  const task = State.focusTask;
  return (task && State.integrations[task.id]?.news) || null;
}

/**
 * The two buttons of a card that tells an integration's news instead of a
 * session's result: into the panel, to what the news is about; or just OK.
 */
function newsActions(actions: ViewActions): HTMLElement {
  return h("div", { class: "actions" },
    btn("Open", "primary", () => actions.followNews()),
    // OK only folds the island: the news stays on the pill until it is opened
    // or gets old, in case it was closed too fast.
    btn("OK", "secondary", () => actions.collapse()),
  );
}

/**
 * What an integration's news puts on a result card, in the card's own three
 * lines: who and what kind of news, the news itself, then the facts that go
 * with it — the step that broke, who merged, how big.
 */
function tellNews(news: IntegrationNews, who: HTMLElement, title: HTMLElement, facts: HTMLElement) {
  who.append(agentWho(State.focusTask, news.open?.says ?? (news.success ? "pull request merged" : "a build broke")));
  title.textContent = news.open?.title ?? news.label;
  clear(facts);
  facts.append(...newsFacts(news));
}

function buildError(actions: ViewActions, onResize: () => void): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title", text: "Workflow stopped." });
  const detail = h("div", { class: "detail" });
  // Where what stopped runs: n8n, the Claude app, a terminal — the pill's own way out.
  const openLabel = h("span");
  const row = h("div", { class: "actions" },
    btn("Retry", "primary", () => actions.setView(State.defaultView())),
    h("button", { class: "btn secondary", onclick: () => actions.openTarget() }, openLabel),
  );
  const facts = h("div", { class: "nfs news-facts" });
  const newsRow = newsActions(actions);
  const lines = stack(116, 16, who, title, detail, facts, row, newsRow);
  const el = h("div", { class: "view" }, card("red", lines));
  const air = airy(lines, onResize);
  return {
    el,
    // A card that tells an integration's news has its own height (NEWS_LINE).
    get height() {
      return frontNews() ? undefined : air.height;
    },
    sync() {
      const task = State.focusTask;
      const news = frontNews();
      row.style.display = news ? "none" : "";
      newsRow.style.display = news ? "" : "none";
      detail.style.display = news ? "none" : "";
      facts.style.display = news ? "" : "none";
      clear(who);
      if (news) {
        tellNews(news, who, title, facts);
        return;
      }
      // A Claude Code session is named by its conversation; n8n and a
      // third-party agent's pill by their own name.
      who.append(task?.id === CLAUDE_ID ? sessionWho("Claude Code") : agentWho(task, task?.source === "n8n" ? "n8n" : "stopped"));
      title.textContent = task?.source === "n8n" ? "Workflow stopped." : "Session stopped on an error.";
      detail.textContent = task?.steps.at(-1) ?? "No detail available.";
      openLabel.textContent =
        task?.source === "n8n" ? "Open in n8n" : task?.id === CLAUDE_ID && State.session.client === "desktop" ? "Open Claude" : "Open terminal";
      air.fit();
    },
  };
}

// ── Finished ──────────────────────────────────────────────────────────────────

function buildFinished(actions: ViewActions, onResize: () => void): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title" });
  // Built once, like every button of a card: only its words follow the session.
  const openLabel = h("span");
  const openBtn = h("button", { class: "btn primary", onclick: () => actions.openTerminal() }, openLabel);
  const changesLabel = h("span");
  const changesBtn = h("button", { class: "btn secondary", onclick: () => actions.openSession(true) }, changesLabel);
  // What Claude said, in full: the card only has room for its first words.
  const readBtn = h("button", { class: "btn primary", onclick: () => actions.openSession() }, h("span", { text: "Read reply" }));
  const row = h("div", { class: "actions" },
    readBtn,
    openBtn,
    changesBtn,
    btn("OK", "secondary", () => actions.collapse()),
  );
  const facts = h("div", { class: "nfs news-facts" });
  const newsRow = newsActions(actions);
  const lines = stack(116, 16, who, title, facts, row, newsRow);
  const el = h("div", { class: "view" }, card("green", lines));
  const air = airy(lines, onResize);
  return {
    el,
    // A card that tells an integration's news has its own height (NEWS_LINE).
    get height() {
      return frontNews() ? undefined : air.height;
    },
    sync() {
      const news = frontNews();
      row.style.display = news ? "none" : "";
      newsRow.style.display = news ? "" : "none";
      facts.style.display = news ? "" : "none";
      clear(who);
      if (news) {
        tellNews(news, who, title, facts);
        return;
      }
      // A third-party agent's pill has no session behind it: its name, its last step, and OK.
      const claude = State.focusTask?.id === CLAUDE_ID;
      who.append(claude ? sessionWho("finished") : agentWho(State.focusTask, "finished"));
      // What Claude said to end its turn, its first line; its last step otherwise.
      const answer = claude ? firstWords(State.session.answer) : null;
      title.textContent = answer ?? State.focusTask?.steps.at(-1) ?? "Session finished";
      // An answer is a sentence, not a step: smaller, and two lines at most.
      title.classList.toggle("said", answer != null);
      readBtn.style.display = answer ? "" : "none";
      openBtn.className = answer ? "btn secondary" : "btn primary";
      // Where the session runs, and what it left behind: the way to its diffs.
      const files = claude ? State.sessionFiles.length : 0;
      openBtn.style.display = claude ? "" : "none";
      openLabel.textContent = State.session.client === "desktop" ? "Open Claude" : "Open terminal";
      changesBtn.style.display = files > 0 ? "" : "none";
      changesLabel.textContent = files === 1 ? "1 file changed" : `${files} files changed`;
      air.fit();
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
  const segButtons = [10, 15, 30].map((s) =>
    h("button", { onclick: () => actions.setAutoClose(s) }, `${s}s`),
  );
  const claudeBadge = h("span", { class: "status-badge" });
  const apiBadge = h("span", { class: "status-badge" });

  const rows = h(
    "div",
    { class: "settings-rows" },
    h("div", { class: "settings-row" }, soundSwitch, h("span", { text: "Sound" }), volume),
    h(
      "div",
      { class: "settings-row" },
      svg(ICONS.timer, 12),
      autoLabel,
      h("div", { class: "seg" }, ...segButtons),
    ),
    h(
      "div",
      { class: "settings-row", style: "gap:14px" },
      claudeBadge,
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
      autoLabel.textContent = `Auto-close · ${Math.round(s.autoCloseInterval)}s`;
      segButtons.forEach((b, i) => b.classList.toggle("on", s.autoCloseInterval === [10, 15, 30][i]));
      clear(claudeBadge);
      claudeBadge.append(
        dot(s.hooksInstalled ? "#22C55E" : "#F4505E", 6),
        h("span", { text: "Claude Code" }),
      );
      clear(apiBadge);
      apiBadge.append(dot("#F4505E", 6), h("span", { text: "API" }));
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
  map.set("overview", buildOverview(actions, onChatHeightChange));
  map.set("empty", buildEmpty(actions));
  map.set("approval", buildApproval(actions, onChatHeightChange));
  map.set("question", buildQuestion(actions, onChatHeightChange));
  map.set("error", buildError(actions, onChatHeightChange));
  map.set("finished", buildFinished(actions, onChatHeightChange));
  map.set("confused", buildConfused());
  map.set("note", buildNote());
  map.set("settings", buildSettings(actions));
  map.set("prompt", buildPrompt(onChatHeightChange));
  map.set("upload", buildUpload());
  map.set("uploading", buildUploading());
  map.set("choose", buildChoose(actions));
  map.set("github", buildGithub(actions));
  map.set("session", buildSession(actions));
  // Not in the Windows v1: sending a file by email, window attach + web result.
  map.set("mail", buildPlaceholder("Sending by email isn't in this version.", ""));
  map.set("searching", buildPlaceholder("Claude is searching…", ""));
  map.set("result", buildPlaceholder("Result", ""));
  return map;
}

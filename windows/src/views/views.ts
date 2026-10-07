// Island views — DOM ports of IslandViewContent.swift. Paddings, font sizes,
// colours and wording are copied from the Swift views so both platforms read
// identically.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { Ticker } from "./ticker";
import { State, agentDisplayName, canOpenOrigin, sessionLabel, sessionOrdinal, sessionTitle, type AgentTask, type QuestionInfo } from "../core/state";
import { allAnswered, currentStep, stepAnswered } from "../core/questions";
import { washRGBA, type IslandViewName, type Wash } from "../core/layout";
import { createMiniBot, pruneMiniBots } from "../mochi/minibots";
import { buildPrompt } from "./chat";
import { buildTask } from "./task";
import { buildRobot } from "./robot";
import { buildChoose, buildUpload, buildUploading } from "./upload";
import { renderIntegrationCard, type IntegrationCardHooks } from "./integrations";

export interface ViewActions {
  setView(v: IslandViewName): void;
  collapse(): void;
  setFocus(id: string): void;
  /** The ↗ button: opens whatever the focused pill points at. */
  openTarget(): void;
  /** Brings the session's originating window (or its folder) to the front. */
  openOrigin(id: string): void;
  openUrl(url: string): void;
  decide(d: "allow" | "deny"): void;
  /** Question card: toggle one option of question `index`. */
  pick(index: number, label: string): void;
  /** Question card: show the previous (-1) or next (+1) question. */
  stepQuestion(delta: -1 | 1): void;
  /** Question card: send every pick to Claude Code. */
  submitAnswers(): void;
  /** Question card: let Claude Code ask in its own interface instead. */
  answerInApp(): void;
  /** Hermes question card: toggle one option of question `index`. */
  pickExternal(index: number, label: string): void;
  /** Hermes question card: show the previous (-1) or next (+1) question. */
  stepExternal(delta: -1 | 1): void;
  /** Hermes question card: send the picks to Hermes. */
  sendExternal(): void;
  toggleSound(): void;
  /** Lock / unlock the island position. */
  toggleLock(): void;
  setVolume(v: number): void;
  setAutoClose(seconds: number): void;
  openSettingsWindow(): void;
  /** First-launch offer: open Settings on "Set up all my agents" (installs nothing). */
  acceptSetupOffer(): void;
  dismissSetupOffer(): void;
  blip(): void;
  /** Keep the island open (no auto-collapse) while a native dialog has the mouse. */
  hold(on: boolean): void;
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
  const tabTask = h("button", { class: "tab tab-task", title: "New task", "aria-label": "New task", onclick: () => go("task") },
    svg(ICONS.plus, 11), h("span", { text: "Task" }));
  const tabRobot = h("button", { class: "tab tab-task", title: "Robot: do a task in the hidden browser", "aria-label": "Robot", onclick: () => go("robot") },
    h("span", { text: "Robot" }));

  const gearBtn = h("button", { title: "Settings", onclick: () => go("settings") }, svg(ICONS.gear, 14));
  const soundBtn = h("button", { title: "Mute", onclick: () => actions.toggleSound() }, svg(ICONS.speakerOn, 14));
  const lockBtn = h("button", { class: "lock-btn", onclick: () => actions.toggleLock() }, svg(ICONS.lock, 13));
  let lockShown: boolean | null = null;

  function go(v: IslandViewName) {
    actions.blip();
    actions.setView(v);
  }

  const el = h(
    "div",
    { id: "header" },
    h("div", { class: "tabs" }, tabHome, tabChat, tabDrop, tabTask, tabRobot),
    h("div", { class: "header-actions" }, lockBtn, gearBtn, soundBtn),
  );

  return {
    el,
    sync() {
      const v = State.view;
      tabHome.classList.toggle("on", v === "overview" || v === "empty");
      tabChat.classList.toggle("on", v === "prompt");
      tabDrop.classList.toggle("on", v === "upload");
      tabTask.classList.toggle("on", v === "task");
      tabRobot.classList.toggle("on", v === "robot");
      gearBtn.classList.toggle("on", v === "settings");
      clear(gearBtn);
      gearBtn.append(svg(v === "settings" ? ICONS.gearFill : ICONS.gear, 14));
      clear(soundBtn);
      soundBtn.append(svg(State.settings.soundEnabled ? ICONS.speakerOn : ICONS.speakerOff, 14));
      const locked = State.settings.islandLocked;
      if (lockShown !== locked) {
        lockShown = locked;
        clear(lockBtn);
        lockBtn.append(svg(locked ? ICONS.lock : ICONS.lockOpen, 13));
        lockBtn.title = locked ? "Unlock position (then drag the island)" : "Lock position";
        lockBtn.setAttribute("aria-label", lockBtn.title);
        lockBtn.classList.toggle("on", !locked);
      }
      el.style.opacity = v === "confused" ? "0" : "1";
    },
  };
}

// ── Overview ──────────────────────────────────────────────────────────────────

function buildOverview(actions: ViewActions): ViewHost {
  const who = h("div", { class: "who" });
  const tickerBody = h("div", { class: "card-body" }, who);
  const leftBody = h("div", { class: "left-body" });
  const jump = h(
    "button",
    { class: "icon-btn jump", title: "Open", onclick: () => actions.openTarget() },
    svg(ICONS.arrowUpRight, 8),
  );
  const left = card(null, leftBody, jump);
  const pills = h("div", { class: "pills" });
  const right = card(null, pills);

  const el = h("div", { class: "view overview" },
    h("div", { class: "left" }, left),
    h("div", { class: "right" }, right),
  );

  let pillIds = "";
  let detailOpen = false;
  let lastFocus: string | null = null;
  let currentTicker = new Ticker();
  tickerBody.append(currentTicker.el);
  let mode: "ticker" | "card" | null = null;
  let cardKey = "";

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
      if (mode === "ticker") currentTicker.tick(nowMs);
    },
    sync() {
      const task = State.focusTask;
      if (task?.id !== lastFocus) {
        lastFocus = task?.id ?? null;
        detailOpen = false;
        cardKey = "";
        mode = null;
        currentTicker = new Ticker();
        clear(tickerBody);
        tickerBody.append(who, currentTicker.el);
      }

      const sessionActive = task && (task.source === "agent" || task.source === "claudeCode") &&
        (task.sessionId != null || task.state !== "idle" || task.steps.length > 0);

      if (task && sessionActive) {
        if (mode !== "ticker") {
          clear(leftBody);
          leftBody.append(tickerBody);
          mode = "ticker";
          cardKey = "";
        }
        clear(who);
        const ordinal = sessionOrdinal(task, State.tasks);
        who.title = sessionTitle(task, State.tasks);
        who.append(
          dot(task.color, 7),
          h("span", { class: "name", text: ordinal ? `${task.name} ${ordinal}` : task.name }),
          h("span", { class: "tool", text: agentDisplayName(task) }),
        );
        if (task.steps.length > 1) {
          who.append(h("span", {
            class: "count",
            text: `${Math.min(task.stepIndex + 1, task.steps.length)}/${task.steps.length}`,
          }));
        }
        currentTicker.sync(task);
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

      const hasTarget = task && (canOpenOrigin(task) || task.id === "integration_n8n" ||
        ["integration_resend", "integration_vercel", "integration_github", "integration_stripe", "integration_notion", "integration_calcom"].includes(task.id));
      jump.style.display = detailOpen || !hasTarget ? "none" : "";
      jump.title = task?.originHwnd != null ? "Open the session window" : task?.source === "claudeCode" ? "Open folder in VS Code" : "Open";
      // `canOpenOrigin` already hides the button for agent sessions with no window.

      const others = State.otherTasks;
      const pillKey = others.map((t) => `${t.id}:${t.name}:${t.pillBadge ?? ""}`).join("|");
      if (pillKey !== pillIds) {
        const scrollTop = pills.scrollTop;
        pillIds = pillKey;
        clear(pills);
        for (const t of others) pills.append(buildPill(t, actions));
        pills.scrollTop = scrollTop;
        pruneMiniBots();
      }
    },
  };
}

function buildPill(task: AgentTask, actions: ViewActions): HTMLElement {
  const label = sessionLabel(task, State.tasks);
  const canvas = createMiniBot(task, 24);
  const pill = h(
    "button",
    { class: "pill", type: "button", title: sessionTitle(task, State.tasks), "aria-label": label, onclick: () => actions.setFocus(task.id) },
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

/**
 * The questions with one button per option. `picked` marks selected labels;
 * without `onPick` the buttons are read-only. Rebuilt only when `key` changes,
 * so a click is never swallowed by a rebuild between mouse-down and mouse-up.
 */
function renderQuestions(
  host: HTMLElement,
  questions: QuestionInfo[],
  picked: string[][] | null,
  onPick: ((index: number, label: string) => void) | null,
  only?: number,
) {
  clear(host);
  questions.forEach((q, i) => {
    if (only != null && i !== only) return;
    const head = h("div", { class: "mcq-q" });
    if (q.header) head.append(h("span", { class: "mcq-tag", text: q.header }));
    head.append(h("span", { text: q.question }));
    if (q.multiSelect) head.append(h("span", { class: "mcq-hint", text: "· choose any" }));
    const opts = h("div", { class: "mcq-opts" });
    for (const o of q.options) {
      const on = picked?.[i]?.includes(o.label) ?? false;
      const b = h("button", {
        class: `mcq-opt${on ? " on" : ""}${onPick ? "" : " ro"}`,
        type: "button",
        title: o.description ?? o.label,
        "aria-pressed": onPick ? String(on) : undefined,
        onclick: onPick ? () => onPick(i, o.label) : undefined,
      }, h("span", { class: "l", text: o.label }), o.description ? h("span", { class: "d", text: o.description }) : null);
      if (!onPick) b.setAttribute("tabindex", "-1");
      opts.append(b);
    }
    host.append(h("div", { class: "mcq-item" }, head, opts));
  });
}

function buildApproval(actions: ViewActions): ViewHost {
  const who = h("div");
  const code = h("div", { class: "code" });
  const row = h("div", { class: "actions" });
  const plain = stack(116, 16, who, code, row);

  const mcqWho = h("div");
  const list = h("div", { class: "mcq-list" });
  const submit = btn("Submit", "primary", () => actions.submitAnswers());
  const back = btn("Back", "secondary", () => actions.stepQuestion(-1));
  const next = btn("Next", "primary", () => actions.stepQuestion(1));
  const counter = h("span", { class: "mcq-count" });
  const openBtn = btn("Open", "secondary", () => {
    const id = State.pendingApproval?.taskId;
    if (id) actions.openOrigin(id);
  });
  const mcqRow = h("div", { class: "actions" },
    btn("Answer in app", "secondary", () => actions.answerInApp()),
    openBtn,
    h("div", { class: "grow" }),
    counter,
    back,
    next,
    submit,
  );
  const mcq = h("div", { class: "stack mcq" }, mcqWho, list, mcqRow);

  const body = card("cyan", plain, mcq);
  const el = h("div", { class: "view" }, body);
  let rowKey = "";
  let listKey = "";
  return {
    el,
    sync() {
      const approval = State.pendingApproval;
      const approvalTask = State.tasks.find((t) => t.id === approval?.taskId) ?? null;
      const questions = approval?.questions ?? null;
      plain.style.display = questions ? "none" : "";
      mcq.style.display = questions ? "" : "none";
      body.style.setProperty("--wash", washRGBA(questions ? "cyan" : "amber"));
      if (questions) {
        clear(mcqWho);
        mcqWho.append(agentWho(approvalTask, questions.length > 1 ? `asks ${questions.length} questions` : "asks a question"));
        const step = currentStep(approval);
        const total = questions.length;
        const key = JSON.stringify([approval!.requestId, approval!.picks, step]);
        if (key !== listKey) {
          listKey = key;
          renderQuestions(list, questions, approval!.picks ?? null, (i, label) => actions.pick(i, label), step);
          list.scrollTop = 0;
        }
        openBtn.style.display = canOpenOrigin(approvalTask) ? "" : "none";
        const last = step === total - 1;
        counter.textContent = total > 1 ? `${step + 1} of ${total}` : "";
        counter.style.display = total > 1 ? "" : "none";
        back.style.display = total > 1 && step > 0 ? "" : "none";
        next.style.display = last ? "none" : "";
        const answered = stepAnswered(approval, step);
        next.toggleAttribute("disabled", !answered);
        next.title = answered ? "Next question" : "Pick an answer first";
        submit.style.display = last ? "" : "none";
        const ready = allAnswered(approval);
        submit.toggleAttribute("disabled", !ready);
        submit.title = ready ? "Send these answers to Claude Code" : "Answer every question first";
        return;
      }
      listKey = "";
      clear(who);
      who.append(agentWho(approvalTask, "needs permission"));
      // The whole point of approving here rather than in the terminal: this line
      // is the command, the file path or the URL being authorised, not just the
      // name of the tool asking.
      code.textContent = State.pendingApproval?.command || State.pendingApproval?.tool || "…";
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

function agentLabel(task: AgentTask | null): string {
  return task ? agentDisplayName(task) : "Agent";
}

/** Hermes questions can be answered from the card (coucou-clarify plugin). */
function answerable(task: AgentTask | null): boolean {
  return task?.agent === "hermes" && !!task.sessionId && !!task.questions?.length;
}

function buildQuestion(actions: ViewActions): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title" });
  const list = h("div", { class: "mcq-list" });
  const openBtn = btn("Open", "primary", () => {
    const task = State.focusTask;
    if (task && canOpenOrigin(task)) actions.openOrigin(task.id);
  });
  // Built once: rebuilding a button between mouse-down and mouse-up swallows the click.
  const hint = h("div", { class: "sub", text: "Answer in your terminal — Coucou can't reply for you yet." });
  let step = 0;
  let stepTask = "";
  const counter = h("span", { class: "mcq-count" });
  const back = btn("Back", "secondary", () => {
    if (answerable(State.focusTask)) return actions.stepExternal(-1);
    step--; listKey = ""; host.sync();
  });
  const next = btn("Next", "secondary", () => {
    if (answerable(State.focusTask)) return actions.stepExternal(1);
    step++; listKey = ""; host.sync();
  });
  const send = btn("Send", "primary", () => actions.sendExternal());
  const row = h("div", { class: "actions" }, hint, h("div", { class: "grow" }), counter, back, next, openBtn, send);
  const body = stack(116, 16, who, title, list, row);
  const el = h("div", { class: "view" }, card("cyan", body));
  let listKey = "";
  const host: ViewHost = {
    el,
    sync() {
      clear(who);
      const task = State.focusTask;
      who.append(agentWho(task, `${agentLabel(task)} is asking a question`));
      const questions = task?.questions ?? null;
      const live = answerable(task);
      body.classList.toggle("mcq", !!questions);
      title.style.display = questions ? "none" : "";
      list.style.display = questions ? "" : "none";
      const status = live ? task!.questionStatus ?? null : null;
      hint.textContent = live
        ? status === "sending" ? "Sending to Hermes…" : status ?? "Answer here or in Hermes."
        : questions
          ? `Answer in ${agentLabel(task)} — Coucou can't reply for it.`
          : "Answer in your terminal — Coucou can't reply for you yet.";
      const total = questions?.length ?? 0;
      if (questions) {
        const id = JSON.stringify([task!.id, questions]);
        if (id !== stepTask) { stepTask = id; step = 0; }
        if (live) step = currentStep(task);
        step = Math.min(Math.max(0, step), total - 1);
        const key = JSON.stringify([id, step, live ? task!.picks : null, status === "sending"]);
        if (key !== listKey) {
          listKey = key;
          const onPick = live && status !== "sending" ? (i: number, label: string) => actions.pickExternal(i, label) : null;
          renderQuestions(list, questions, live ? task!.picks ?? null : null, onPick, step);
        }
      } else {
        listKey = "";
        stepTask = "";
        step = 0;
        title.textContent = task?.steps.at(-1) ?? "Answer needed.";
      }
      counter.textContent = total > 1 ? `${step + 1} of ${total}` : "";
      counter.style.display = total > 1 ? "" : "none";
      back.style.display = total > 1 && step > 0 ? "" : "none";
      const last = step >= total - 1;
      next.style.display = total > 1 && !last ? "" : "none";
      const stepDone = live ? stepAnswered(task, step) : true;
      next.toggleAttribute("disabled", !stepDone);
      next.title = stepDone ? "Next question" : "Pick an answer first";
      openBtn.style.display = canOpenOrigin(task) ? "" : "none";
      openBtn.classList.toggle("primary", !live);
      openBtn.classList.toggle("secondary", live);
      send.style.display = live && last ? "" : "none";
      const ready = live && allAnswered(task) && status !== "sending";
      send.toggleAttribute("disabled", !ready);
      send.title = ready ? "Send these answers to Hermes" : "Answer every question first";
    },
  };
  return host;
}

// ── Approval notice (Kimi, Hermes) ────────────────────────────────────────────

/**
 * A Kimi or Hermes approval, shown so it is not missed. Their hooks cannot
 * answer it, so the card only says what is asked and opens the agent's window.
 */
function buildNotice(actions: ViewActions): ViewHost {
  const who = h("div");
  const code = h("div", { class: "code" });
  const openBtn = btn("Open", "primary", () => {
    const task = State.focusTask;
    if (task && canOpenOrigin(task)) actions.openOrigin(task.id);
  });
  const hint = h("div", { class: "sub" });
  const row = h("div", { class: "actions" }, hint, h("div", { class: "grow" }), openBtn);
  const body = card("amber", stack(116, 16, who, code, row));
  return {
    el: h("div", { class: "view" }, body),
    sync() {
      const task = State.focusTask;
      clear(who);
      who.append(agentWho(task, "needs permission"));
      code.textContent = task?.approvalNotice ?? "…";
      hint.textContent = `Approve or deny in ${agentLabel(task)}.`;
      openBtn.style.display = canOpenOrigin(task) ? "" : "none";
    },
  };
}

// ── Error ─────────────────────────────────────────────────────────────────────

function buildError(actions: ViewActions): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title", text: "Workflow stopped." });
  const detail = h("div", { class: "detail" });
  const row = h("div", { class: "actions" },
    btn("OK", "secondary", () => actions.setView(State.defaultView())),
  );
  const el = h("div", { class: "view" }, card("red", stack(116, 16, who, title, detail, row)));
  return {
    el,
    sync() {
      const task = State.focusTask;
      clear(who);
      who.append(agentWho(task, agentLabel(task)));
      title.textContent = task?.source === "n8n" ? "Workflow stopped." : "Session stopped on an error.";
      detail.textContent = task?.steps.at(-1) ?? "No detail available.";
    },
  };
}

// ── Finished ──────────────────────────────────────────────────────────────────

function buildFinished(actions: ViewActions): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title" });
  const open = () => {
    const task = State.focusTask;
    if (task && canOpenOrigin(task)) actions.openOrigin(task.id);
  };
  const openBtn = btn("Open", "primary", open);
  const okBtn = btn("OK", "secondary", () => actions.collapse());
  // OK must only dismiss, never also open.
  okBtn.addEventListener("click", (e) => e.stopPropagation());
  openBtn.addEventListener("click", (e) => e.stopPropagation());
  const row = h("div", { class: "actions" }, okBtn, openBtn);
  const body = card("green", stack(116, 16, who, title, row));
  body.addEventListener("click", open);
  const el = h("div", { class: "view" }, body);
  return {
    el,
    sync() {
      clear(who);
      const task = State.focusTask;
      who.append(agentWho(task, `${agentLabel(task)} finished`));
      title.textContent = task?.steps.at(-1) ?? "Session finished";
      const openable = canOpenOrigin(task);
      openBtn.style.display = openable ? "" : "none";
      body.classList.toggle("openable", openable);
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

// ── First-launch setup offer ──────────────────────────────────────────────────

function buildSetupOffer(actions: ViewActions): ViewHost {
  const title = h("div", { class: "title" });
  const detail = h("div", { class: "detail", text: "Settings shows what changes. Nothing is installed until you click." });
  const row = h("div", { class: "actions" },
    btn("Not now", "secondary", () => actions.dismissSetupOffer()),
    btn("Set them up", "primary", () => actions.acceptSetupOffer()),
  );
  const el = h("div", { class: "view" }, card("green", stack(116, 16, title, detail, row)));
  return {
    el,
    sync() {
      title.textContent = setupOfferText(State.setupOffer);
    },
  };
}

export function setupOfferText(names: string[]): string {
  return `Coucou found: ${names.join(", ")}. Set them up?`;
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
  map.set("overview", buildOverview(actions));
  map.set("empty", buildEmpty(actions));
  map.set("approval", buildApproval(actions));
  map.set("question", buildQuestion(actions));
  map.set("notice", buildNotice(actions));
  map.set("error", buildError(actions));
  map.set("finished", buildFinished(actions));
  map.set("confused", buildConfused());
  map.set("note", buildNote());
  map.set("settings", buildSettings(actions));
  map.set("setupOffer", buildSetupOffer(actions));
  map.set("prompt", buildPrompt(onChatHeightChange));
  map.set("task", buildTask(() => actions.setView(State.defaultView()), (on) => actions.hold(on)));
  map.set("robot", buildRobot(() => actions.setView(State.defaultView())));
  map.set("upload", buildUpload());
  map.set("uploading", buildUploading());
  map.set("choose", buildChoose(actions));
  // Not in the Windows v1: sending a file by email, window attach + web result.
  map.set("mail", buildPlaceholder("Sending by email isn't in this version.", ""));
  map.set("searching", buildPlaceholder("Claude is searching…", ""));
  map.set("result", buildPlaceholder("Result", ""));
  return map;
}

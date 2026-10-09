// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView /
// ModelPickerView from IslandViewContent.swift.
//
// Answers are rendered as Markdown (markdown.ts). A local model streams its
// answer: Rust sends `chat-delta` events with the text visible so far. The
// model name above the text field opens the picker: provider chips, then the
// models of the chosen provider, asked for only once it is picked.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { renderMarkdown } from "./markdown";
import {
  Bridge, onEvent, type ChatContext, type ModelInfo, type TaskResult, type TaskStarted,
} from "../core/bridge";
import {
  activeModel, pickModel, providerDef, visibleProviders, withModel, type ProviderDef,
} from "../core/providers";
import { Sound } from "../core/sound";
import { State, type ChatMessage } from "../core/state";
import type { ViewHost } from "./views";
import { N_, t, tl } from "../i18n/i18n";

const STRINGS = {
  placeholderFirst: N_("Ask me anything…"),
  placeholderNext: N_("Continue…"),
  send: N_("Send"),
  switchModel: N_("Switch provider or model"),
  noModel: N_("Choose a model"),
  loading: N_("Loading models…"),
  noKey: N_("No API key — add it in Settings."),
  openSettings: N_("Open Settings"),
  task: N_("Task"),
  taskHint: N_("Hand the next message to Claude Code as a task"),
  taskProject: N_("Project folder the task runs in"),
  placeholderTask: N_("Describe a task — Claude Code runs it in the chosen folder…"),
  taskRunning: N_("*Running — follow it in the island…*"),
  cancel: N_("Cancel"),
  noProject: N_("No project folder found — set Task projects in Settings."),
  followUp: N_("Follow up"),
  openFolder: N_("Open folder"),
  placeholderFollowUp: N_("Follow up — continues the same task…"),
  otherFolder: N_("Other…"),
  typePath: N_("Full path of a folder — Enter to use it, Esc to go back"),
};

/** "Other…" keeps this many typed folders on the list. */
const MAX_RECENT_DIRS = 8;

let nextId = 1;

function bubble(message: ChatMessage, onFollowUp?: (m: ChatMessage) => void): HTMLElement {
  if (message.role === "user") {
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "bubble", text: message.content }),
    );
  }
  const reply = h("div", { class: "reply" });
  renderMarkdown(reply, message.content);
  const row = h("div", { class: "chat-row" }, reply);
  if (message.taskId == null) return row;
  if (message.pending) {
    const taskId = message.taskId;
    row.append(
      h("button", {
        class: "task-cancel",
        text: tl(STRINGS.cancel),
        onclick: () => void Bridge.taskCancel(taskId),
      }),
    );
    return row;
  }
  // A finished task: its folder, and a follow-up in the same session.
  const actions = h("div", { class: "task-actions" });
  const dir = message.taskDir;
  if (dir) {
    actions.append(
      h("button", {
        class: "task-action",
        text: tl(STRINGS.openFolder),
        onclick: () => void Bridge.taskReveal(dir),
      }),
    );
  }
  if (dir && message.sessionId && onFollowUp) {
    actions.append(
      h("button", {
        class: "task-action",
        text: tl(STRINGS.followUp),
        onclick: () => onFollowUp(message),
      }),
    );
  }
  if (actions.childElementCount > 0) row.append(actions);
  return row;
}

function typingDots(): HTMLElement {
  return h(
    "div",
    { class: "chat-row" },
    h("div", { class: "typing" }, h("i"), h("i"), h("i")),
  );
}

/** The coloured chip showing what the question is about (a dropped file). */
function contextChip(label: string): HTMLElement {
  const chip = h("div", { class: "chip" }, h("i", { class: "chip-dot" }), h("span", { text: label }));
  requestAnimationFrame(() => chip.classList.add("settled"));
  return chip;
}

function saveSettings() {
  void Bridge.saveSettings(State.settings);
}

// ── Model picker ──────────────────────────────────────────────────────────────

interface Picker {
  el: HTMLElement;
  open(): void;
  close(): void;
  readonly isOpen: boolean;
}

/** Provider chips, then the chosen provider's models — ModelPickerView. */
function buildPicker(onChange: () => void): Picker {
  const chips = h("div", { class: "picker-chips" });
  const list = h("div", { class: "picker-list" });
  const el = h("div", { class: "picker" }, chips, h("div", { class: "picker-rule" }), list);

  /** Models already asked for, by provider; a model server is asked again each time. */
  const cache = new Map<string, ModelInfo[]>();
  let isOpen = false;
  let request = 0;

  function drawChips() {
    clear(chips);
    for (const p of visibleProviders(State.settings)) {
      const on = p.id === State.settings.chatProvider;
      const chip = h(
        "button",
        { class: on ? "picker-chip on" : "picker-chip", style: `--accent:${p.accent}` },
        h("i", { class: "picker-dot" }),
        h("span", { text: t(p.name) }),
      );
      chip.addEventListener("click", () => {
        if (p.id === State.settings.chatProvider) return;
        State.settings = { ...State.settings, chatProvider: p.id };
        saveSettings();
        Sound.play("pop");
        drawChips();
        void loadModels();
        onChange();
      });
      chips.append(chip);
    }
  }

  function status(text: string, withSettings = false) {
    clear(list);
    const line = h("div", { class: "picker-status", text });
    if (withSettings) {
      line.append(
        h("button", {
          class: "picker-link",
          text: tl(STRINGS.openSettings),
          onclick: () => void Bridge.openSettingsWindow(),
        }),
      );
    }
    list.append(line);
  }

  function drawModels(p: ProviderDef, models: ModelInfo[]) {
    clear(list);
    const current = activeModel(State.settings);
    for (const m of models) {
      const on = m.id === current;
      const row = h(
        "button",
        { class: on ? "picker-model on" : "picker-model", style: `--accent:${p.accent}`, title: m.id },
        h("span", { class: "picker-model-name", text: m.label }),
        on ? svg(ICONS.check, 11, { stroke: 2.2 }) : null,
      );
      row.addEventListener("click", () => {
        State.settings = withModel(State.settings, p.id, m.id);
        saveSettings();
        Sound.play("blip");
        close();
      });
      list.append(row);
    }
    list.querySelector(".picker-model.on")?.scrollIntoView({ block: "nearest" });
  }

  async function loadModels() {
    const p = providerDef(State.settings.chatProvider);
    const ticket = ++request;
    const cached = p.urlField ? undefined : cache.get(p.id);
    if (cached) {
      drawModels(p, cached);
      return;
    }
    // Nothing is asked of a provider that has no key yet.
    if (p.key && !(await Bridge.secretPresent(p.key))) {
      if (ticket === request) status(t(STRINGS.noKey), true);
      return;
    }
    if (ticket !== request) return;
    status(t(STRINGS.loading));
    try {
      const models = await Bridge.chatModels(p.id);
      if (ticket !== request) return;
      if (!p.urlField) cache.set(p.id, models);
      const keep = pickModel(p, models.map((m) => m.id), activeModel(State.settings));
      if (keep && keep !== activeModel(State.settings)) {
        State.settings = withModel(State.settings, p.id, keep);
        saveSettings();
        onChange();
      }
      drawModels(p, models);
    } catch (err) {
      if (ticket === request) status(String(err).replace(/^Error:\s*/, ""), Boolean(p.key));
    }
  }

  function open() {
    isOpen = true;
    el.classList.add("on");
    drawChips();
    onChange();
    void loadModels();
  }

  function close() {
    isOpen = false;
    request++;
    el.classList.remove("on");
    onChange();
  }

  return {
    el,
    open,
    close,
    get isOpen() {
      return isOpen;
    },
  };
}

// ── View ──────────────────────────────────────────────────────────────────────

export function buildPrompt(onHeightChange: () => void): ViewHost {
  const chipRow = h("div", { class: "chip-row" });
  const log = h("div", { class: "chat-log" });
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: t(STRINGS.placeholderFirst),
    spellcheck: "false",
  }) as HTMLInputElement;
  const send = h("button", { class: "send-btn", title: tl(STRINGS.send) }, svg(ICONS.arrowUp, 11));
  const bar = h("div", { class: "chat-bar" }, input, send);

  const modelDot = h("i", { class: "model-dot" });
  const modelName = h("span", { class: "model-name" });
  const modelBtn = h(
    "button",
    { class: "model-btn", title: tl(STRINGS.switchModel) },
    modelDot,
    modelName,
    svg(ICONS.chevronUpDown, 9, { stroke: 2 }),
  );
  // Task mode: the next message is handed to `claude -p` in the chosen folder
  // rather than to the chat provider. The folder list comes from Rust.
  let taskMode = false;
  const taskBtn = h("button", { class: "task-btn", title: tl(STRINGS.taskHint), text: tl(STRINGS.task) });
  const dirSelect = h("select", { class: "task-dir", title: tl(STRINGS.taskProject) }) as HTMLSelectElement;
  // "Other…": the select steps aside for a text field taking any full path,
  // dotted folders included; Enter keeps it (and remembers it), Esc goes back.
  const dirInput = h("input", {
    type: "text",
    class: "task-dir task-dir-input",
    placeholder: tl(STRINGS.typePath),
    spellcheck: "false",
  }) as HTMLInputElement;
  const modelRow = h("div", { class: "model-row" }, taskBtn, dirSelect, dirInput, modelBtn);

  const body = h("div", { class: "chat-body" });
  const picker = buildPicker(() => {
    body.classList.toggle("picking", picker.isOpen);
    drawModelButton();
  });
  body.append(chipRow, log, picker.el, modelRow, bar);

  const el = h("div", { class: "view" }, h("div", { class: "card wash chat-card" }, body));
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;
  // Bumped when a bubble changes without the count changing (a task's answer).
  let epoch = 0;
  // A local model answers token by token: where its text so far is shown.
  let live: HTMLElement | null = null;

  function dirOption(path: string): HTMLOptionElement {
    const name = path.replace(/[/\\]+$/, "").split(/[/\\]/).pop() || path;
    return h("option", { value: path, text: name, title: path }) as HTMLOptionElement;
  }

  async function loadProjects() {
    const fromRoot = (await Bridge.taskProjects()) ?? [];
    const dirs = [...fromRoot];
    for (const recent of State.settings.taskRecentDirs) {
      if (!dirs.includes(recent)) dirs.push(recent);
    }
    clear(dirSelect);
    for (const path of dirs) dirSelect.append(dirOption(path));
    dirSelect.append(h("option", { value: "__other__", text: t(STRINGS.otherFolder) }));
    const last = State.settings.taskLastProject;
    if (last && dirs.includes(last)) dirSelect.value = last;
  }

  /** The typed folder goes to the top of the list and is remembered. */
  function commitTypedDir() {
    const typed = dirInput.value.trim().replace(/[/\\]+$/, "");
    if (!typed) return;
    dirInput.classList.remove("on");
    dirSelect.classList.add("on");
    const existing = Array.from(dirSelect.options).find((o) => o.value === typed);
    if (!existing) dirSelect.prepend(dirOption(typed));
    dirSelect.value = typed;
    const recents = [typed, ...State.settings.taskRecentDirs.filter((d) => d !== typed)];
    State.settings = { ...State.settings, taskRecentDirs: recents.slice(0, MAX_RECENT_DIRS) };
    saveSettings();
    input.focus();
  }

  dirSelect.addEventListener("change", () => {
    if (dirSelect.value !== "__other__") return;
    dirSelect.classList.remove("on");
    dirInput.classList.add("on");
    dirInput.value = "";
    dirInput.focus();
  });

  dirInput.addEventListener("keydown", (e) => {
    const key = (e as KeyboardEvent).key;
    if (key === "Enter") {
      e.preventDefault();
      commitTypedDir();
    } else if (key === "Escape") {
      e.preventDefault();
      dirInput.classList.remove("on");
      dirSelect.classList.add("on");
      if (dirSelect.value === "__other__") dirSelect.selectedIndex = 0;
      input.focus();
    }
    e.stopPropagation(); // Escape closes the island, not the field
  });

  // A follow-up in flight: the next task resumes this bubble's session.
  let followUpTarget: ChatMessage | null = null;

  function startFollowUp(message: ChatMessage) {
    followUpTarget = message;
    if (!taskMode) {
      taskMode = true;
      void loadProjects();
    }
    taskBtn.classList.add("on");
    dirSelect.classList.add("on");
    Sound.play("pop");
    input.placeholder = t(STRINGS.placeholderFollowUp);
    input.focus();
  }

  taskBtn.addEventListener("click", () => {
    taskMode = !taskMode;
    if (taskMode) void loadProjects();
    else followUpTarget = null;
    Sound.play("pop");
    taskBtn.classList.toggle("on", taskMode);
    dirSelect.classList.toggle("on", taskMode);
    dirInput.classList.remove("on");
    input.placeholder = t(
      taskMode ? STRINGS.placeholderTask
      : State.chatHistory.length === 0 ? STRINGS.placeholderFirst : STRINGS.placeholderNext,
    );
    input.focus();
  });

  function drawModelButton() {
    const p = providerDef(State.settings.chatProvider);
    modelDot.style.background = p.accent;
    modelName.textContent = activeModel(State.settings) || t(STRINGS.noModel);
    modelBtn.classList.toggle("open", picker.isOpen);
    modelBtn.disabled = sending;
  }

  modelBtn.addEventListener("click", () => {
    if (sending) return;
    if (picker.isOpen) picker.close();
    else picker.open();
  });

  void onEvent<TaskStarted>("task-started", (started) => {
    const message = State.chatHistory.find((m) => m.taskId === started.taskId);
    if (message) message.sessionId = started.sessionId;
  });

  void onEvent<TaskResult>("task-result", (result) => {
    const message = State.chatHistory.find((m) => m.taskId === result.taskId);
    if (!message || !message.pending) return;
    message.pending = false;
    message.content = result.text;
    epoch++;
    Sound.play(result.ok ? "finish" : "error");
    State.notify();
    onHeightChange();
  });

  void onEvent<string>("chat-delta", (text) => {
    if (!sending || !text) return; // nothing visible yet: the dots stay
    if (!live) {
      live = h("div", { class: "reply" });
      log.querySelector(".typing")?.parentElement?.remove();
      log.append(h("div", { class: "chat-row" }, live));
    }
    renderMarkdown(live, text);
    log.scrollTop = log.scrollHeight;
  });

  /** Task mode's send: the task goes to `claude -p`, the chat stays usable. */
  async function submitTask(query: string) {
    const target = followUpTarget;
    followUpTarget = null;
    let dir = target?.taskDir ?? dirSelect.value;
    if (dir === "__other__") {
      commitTypedDir();
      dir = dirSelect.value;
    }
    if (!dir || dir === "__other__") {
      State.noteMessage = t(STRINGS.noProject);
      State.view = "note";
      State.notify();
      return;
    }
    input.value = "";
    Sound.play("send");
    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    const placeholder: ChatMessage = {
      id: nextId++, role: "assistant", content: t(STRINGS.taskRunning), pending: true, taskDir: dir,
    };
    State.chatHistory.push(placeholder);
    State.notify();
    onHeightChange();
    try {
      placeholder.taskId = await Bridge.taskSpawn(query, dir, target?.sessionId ?? null);
      if (State.settings.taskLastProject !== dir) {
        State.settings = { ...State.settings, taskLastProject: dir };
        saveSettings();
      }
    } catch (err) {
      placeholder.pending = false;
      placeholder.content = String(err).replace(/^Error:\s*/, "");
      Sound.play("error");
    }
    epoch++; // the bubble gained its Cancel, or the error text
    State.notify();
    onHeightChange();
    input.focus();
  }

  async function submit() {
    const query = input.value.trim();
    if (!query || sending) return;
    if (picker.isOpen) picker.close();
    if (taskMode) {
      await submitTask(query);
      return;
    }
    input.value = "";
    sending = true;
    drawModelButton();
    Sound.play("send");

    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const file = State.droppedFile;
    const context: ChatContext | null =
      State.chatHistory.length === 1 && file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      const reply = await Bridge.chatSend(query, context);
      State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text });
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      State.stateOverride = null;
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";
      Sound.play("error");
    } finally {
      sending = false;
      live = null;
      renderedCount = -1; // the finished answer replaces the streamed one
      drawModelButton();
      State.notify();
      onHeightChange();
      input.focus();
    }
  }

  send.addEventListener("click", () => void submit());
  input.addEventListener("keydown", (e) => {
    const key = (e as KeyboardEvent).key;
    if (key === "Enter") {
      e.preventDefault();
      void submit();
    } else if (key === "Escape" && picker.isOpen) {
      e.preventDefault();
      picker.close();
    }
    e.stopPropagation(); // Escape closes the island, not the chat
  });

  return {
    el,
    sync() {
      const file = State.droppedFile;
      const wantChip = file?.name ?? "";
      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;
        clear(chipRow);
        if (wantChip) chipRow.append(contextChip(wantChip));
      }

      const thinking = State.stateOverride === "thinking";
      const count = State.chatHistory.length + (thinking ? 0.5 : 0) + epoch * 1000;
      if (count !== renderedCount && !live) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m, startFollowUp));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
      }

      // Leaving the chat folds the picker away.
      if (State.view !== "prompt" && picker.isOpen) picker.close();
      drawModelButton();

      input.placeholder = t(
        followUpTarget ? STRINGS.placeholderFollowUp
        : taskMode ? STRINGS.placeholderTask
        : State.chatHistory.length === 0 ? STRINGS.placeholderFirst : STRINGS.placeholderNext,
      );
      input.disabled = sending;
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}

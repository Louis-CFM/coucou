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
import { Bridge, onEvent, type ChatContext, type ModelInfo } from "../core/bridge";
import {
  activeModel, pickModel, providerDef, visibleProviders, withModel, type ProviderDef,
} from "../core/providers";
import { codexSelection, effortLabel, codexModelLabel } from "../core/codex";
import { codexControls } from "./codex-picker";
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
};

let nextId = 1;

function bubble(message: ChatMessage): HTMLElement {
  if (message.role === "user") {
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "bubble", text: message.content }),
    );
  }
  const reply = h("div", { class: "reply" });
  renderMarkdown(reply, message.content);
  return h("div", { class: "chat-row" }, reply);
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
  readonly height: number;
}

/** Provider chips, then the chosen provider's models — ModelPickerView. */
function buildPicker(onChange: () => void): Picker {
  const chips = h("div", { class: "picker-chips" });
  const list = h("div", { class: "picker-list" });
  const heading = h("div", { class: "codex-model-heading" });
  const controls = h("div", { class: "codex-controls" });
  const content = h("div", { class: "picker-content" }, list, controls);
  const el = h("div", { class: "picker" }, heading, chips, h("div", { class: "picker-rule" }), content);

  /** Models already asked for, by provider; a model server is asked again each time. */
  const cache = new Map<string, ModelInfo[]>();
  let isOpen = false;
  let request = 0;
  let codexPage: "controls" | "models" | "providers" = "controls";
  let resizing: Animation | null = null;
  let shown = false;

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
        if (p.id === State.settings.chatProvider) {
          if (p.id === "codex") { codexPage = "controls"; drawModels(p, cache.get(p.id) ?? []); onChange(); }
          return;
        }
        codexPage = "controls";
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

  function status(text: string, withSettings = false, retry = false) {
    clear(list);
    clear(heading);
    clear(controls);
    const codex = State.settings.chatProvider === "codex";
    el.classList.toggle("codex-picker", codex);
    el.classList.toggle("codex-status", codex);
    el.classList.remove("codex-models-mode", "codex-providers-mode");
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
    if (retry) line.append(h("button", {class: "picker-link", text: tl("Retry"), onclick: () => void loadModels()}));
  }

  function drawModels(p: ProviderDef, models: ModelInfo[]) {
    const before = typeof el.animate === "function" && isOpen && shown ? el.getBoundingClientRect().height : 0;
    resizing?.cancel();
    clear(list);
    clear(heading);
    const current = activeModel(State.settings);
    const codex = p.id === "codex";
    el.classList.remove("codex-status");
    el.classList.toggle("codex-picker", codex);
    el.classList.toggle("codex-providers-mode", codex && codexPage === "providers");
    el.classList.toggle("codex-models-mode", codex && codexPage === "models");
    clear(controls);
    const selected = models.find(m => m.id === current);
    const page = (next: typeof codexPage) => {
      codexPage = next; drawModels(p, models); onChange();
    };
    if (codex && selected) {
      controls.append(codexControls(selected, () => page("models"), save => {
        if (save) saveSettings(); onChange();
      }));
      const back = h("button", {class: "codex-back", "aria-label": tl("Back"), onclick: () => page("controls")},
        svg(ICONS.chevronLeft, 12, {stroke: 1.7}));
      heading.append(back,
        h("span", {text: tl(codexPage === "providers" ? N_("Switch provider") : N_("Select model"))}),
        h("button", {class: "codex-providers", title: tl("Switch provider"), "aria-label": tl("Switch provider"), onclick: () => page("providers")}, svg(ICONS.ellipsis, 15)));
    }
    for (const m of models) {
      const on = m.id === current;
      const row = h(
        "button",
        { class: on ? "picker-model on" : "picker-model", style: `--accent:${p.accent}`, title: m.id },
        h("span", { class: "picker-model-name", text: m.label }),
        on ? svg(ICONS.check, 11, { stroke: 2.2 }) : null,
      );
      row.addEventListener("click", () => {
        State.settings = p.id === "codex" ? codexSelection(State.settings, m) : withModel(State.settings, p.id, m.id);
        saveSettings();
        Sound.play("blip");
        if (p.id === "codex") { codexPage = "controls"; drawModels(p, models); onChange(); } else close();
      });
      list.append(row);
    }
    if (!codex || codexPage !== "controls") list.querySelector(".picker-model.on")?.scrollIntoView({ block: "nearest" });
    if (before > 0 && !window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) {
      const after = el.getBoundingClientRect().height;
      if (Math.abs(after - before) > 1) resizing = el.animate(
        [{ height: `${before}px` }, { height: `${after}px` }],
        { duration: 220, easing: "cubic-bezier(.2,.8,.2,1)" },
      );
    }
    shown = true;
    onChange();
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
      const keep = p.id === "codex" && !models.some(m => m.id === activeModel(State.settings))
        ? (models.find(m => m.isDefault) ?? models[0])?.id
        : pickModel(p, models.map((m) => m.id), activeModel(State.settings));
      if (keep && keep !== activeModel(State.settings)) {
        State.settings = withModel(State.settings, p.id, keep);
        saveSettings();
        onChange();
      }
      if (p.id === "codex") {
        const model = models.find(m => m.id === keep);
        if (model) {
          const next = codexSelection(State.settings, model);
          if (next.codexReasoningEffort !== State.settings.codexReasoningEffort || next.codexServiceTier !== State.settings.codexServiceTier) {
            State.settings = next; saveSettings(); onChange();
          }
        }
      }
      drawModels(p, models);
    } catch (err) {
      if (ticket === request) status(String(err).replace(/^Error:\s*/, ""), Boolean(p.key), true);
    }
  }

  function open() {
    shown = false;
    resizing?.cancel();
    codexPage = "controls";
    isOpen = true;
    el.classList.add("on");
    drawChips();
    onChange();
    void loadModels();
  }

  function close() {
    isOpen = false;
    shown = false;
    request++;
    el.classList.remove("on");
    onChange();
  }

  return {
    el,
    open,
    close,
    get height() { return 320; },
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
  const modelRow = h("div", { class: "model-row" }, modelBtn);

  const body = h("div", { class: "chat-body" });
  const picker = buildPicker(() => {
    body.classList.toggle("picking", picker.isOpen);
    drawModelButton();
    if (State.chatPickerOpen !== picker.isOpen || State.chatPickerHeight !== picker.height) {
      State.chatPickerOpen = picker.isOpen;
      State.chatPickerHeight = picker.height;
      State.notify();
      onHeightChange();
    }
  });
  body.append(chipRow, log, picker.el, modelRow, bar);
  // Inactive views are not synced by the island. Fold the menu immediately
  // when leaving so returning to chat starts at its normal height.
  State.subscribe(() => {
    if ((State.view !== "prompt" || State.mode !== "expanded") && picker.isOpen) picker.close();
  });

  const el = h("div", { class: "view" }, h("div", { class: "card wash chat-card" }, body));
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let stopped = false;
  let activeHistory: ChatMessage[] | null = null;
  let codexEnabled = State.settings.codexChatEnabled;
  let renderedCount = -1;
  // A local model answers token by token: where its text so far is shown.
  let live: HTMLElement | null = null;

  function drawModelButton() {
    const p = providerDef(State.settings.chatProvider);
    modelDot.style.background = p.accent;
    const model = activeModel(State.settings);
    modelName.textContent = p.id === "codex" && model
      ? [codexModelLabel(model), State.settings.codexReasoningEffort ? t(effortLabel(State.settings.codexReasoningEffort)) : "",
          State.settings.codexServiceTier ? t("Fast") : ""].filter(Boolean).join(" · ")
      : model || t(STRINGS.noModel);
    modelBtn.classList.toggle("open", picker.isOpen);
    modelBtn.disabled = sending;
  }

  modelBtn.addEventListener("click", () => {
    if (sending) return;
    if (picker.isOpen) picker.close();
    else picker.open();
  });

  void onEvent<string>("chat-delta", (text) => {
    if (!sending || State.chatHistory !== activeHistory || !text) return; // nothing visible yet: the dots stay
    if (!live) {
      live = h("div", { class: "reply" });
      log.querySelector(".typing")?.parentElement?.remove();
      log.append(h("div", { class: "chat-row" }, live));
    }
    renderMarkdown(live, text);
    log.scrollTop = log.scrollHeight;
  });

  async function submit() {
    const query = input.value.trim();
    if (!query || sending) return;
    if (picker.isOpen) picker.close();
    input.value = "";
    sending = true;
    activeHistory = State.chatHistory;
    const conversation = activeHistory;
    stopped = false;
    drawSendButton();
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
      if (State.chatHistory !== conversation) return;
      State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text });
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      if (stopped || State.chatHistory !== conversation) return;
      State.stateOverride = null;
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";
      Sound.play("error");
    } finally {
      sending = false;
      State.stateOverride = null;
      drawSendButton();
      live = null;
      renderedCount = -1; // the finished answer replaces the streamed one
      drawModelButton();
      State.notify();
      onHeightChange();
      input.focus();
    }
  }

  function drawSendButton() {
    clear(send);
    const canStop = sending && State.settings.chatProvider === "codex";
    send.append(svg(canStop ? "M6 6h12v12H6z" : ICONS.arrowUp, 11));
    send.title = t(canStop ? N_("Stop response") : STRINGS.send);
    send.setAttribute("aria-label", send.title);
  }
  send.addEventListener("click", () => {
    if (sending && State.settings.chatProvider === "codex") {
      stopped = true;
      void Bridge.chatCancel();
    } else void submit();
  });
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
      const count = State.chatHistory.length + (thinking ? 0.5 : 0);
      if (count !== renderedCount && !live) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
      }

      if (codexEnabled !== State.settings.codexChatEnabled) {
        codexEnabled = State.settings.codexChatEnabled;
        if (!codexEnabled && sending) stopped = true;
        if (picker.isOpen) picker.close();
      }
      // Leaving the chat folds the picker away.
      if (State.view !== "prompt" && picker.isOpen) picker.close();
      drawModelButton();

      input.placeholder = t(State.chatHistory.length === 0 ? STRINGS.placeholderFirst : STRINGS.placeholderNext);
      input.disabled = sending;
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}

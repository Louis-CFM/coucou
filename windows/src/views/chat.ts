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
import { Bridge, emitToWindow, onEvent, type ChatContext, type ModelInfo } from "../core/bridge";
import {
  activeModel, pickModel, providerDef, providerForPill, visibleProviders, withModel, type ProviderDef,
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
    for (const p of visibleProviders(State.settings).filter(p => !State.settings.companionMode || p.id === providerForPill(State.focusId ?? undefined))) {
      const on = p.id === State.chatProvider;
      const chip = h(
        "button",
        { class: on ? "picker-chip on" : "picker-chip", style: `--accent:${p.accent}` },
        h("i", { class: "picker-dot" }),
        h("span", { text: t(p.name) }),
      );
      chip.addEventListener("click", () => {
        if (p.id === State.chatProvider) return;
        State.settings = { ...State.settings, chatProvider: p.id };
        saveSettings();
        State.notify();
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
    const current = activeModel({ ...State.settings, chatProvider: State.chatProvider });
    for (const m of models) {
      const on = m.id === current;
      const row = h(
        "button",
        { class: on ? "picker-model on" : "picker-model", style: `--accent:${p.accent}`, title: m.id },
        h("span", { class: "picker-model-name", text: m.label }),
        on ? svg(ICONS.check, 11, { stroke: 2.2 }) : null,
      );
      row.addEventListener("click", () => {
        State.settings = { ...withModel(State.settings, p.id, m.id), chatProvider: State.settings.chatProvider };
        saveSettings();
        Sound.play("blip");
        close();
      });
      list.append(row);
    }
    list.querySelector(".picker-model.on")?.scrollIntoView({ block: "nearest" });
  }

  async function loadModels() {
    const p = providerDef(State.chatProvider);
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
      const keep = pickModel(p, models.map((m) => m.id), activeModel({ ...State.settings, chatProvider: State.chatProvider }));
      if (keep && keep !== activeModel({ ...State.settings, chatProvider: State.chatProvider })) {
        State.settings = { ...withModel(State.settings, p.id, keep), chatProvider: State.settings.chatProvider };
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
  const modelRow = h("div", { class: "model-row" }, modelBtn);

  const body = h("div", { class: "chat-body" });
  const requests = h("div", { class: "cli-requests", style: "max-height:190px;overflow:auto" });
  const picker = buildPicker(() => {
    body.classList.toggle("picking", picker.isOpen);
    drawModelButton();
  });
  body.append(chipRow, log, requests, picker.el, modelRow, bar);

  const requestCards = new Map<string, HTMLElement>();
  void onEvent<{ id: string; provider: string; kind: string; detail: string;
    questions?: { id: string; question: string; isSecret?: boolean; options?: { label: string }[] }[] | null
  }>("agent-request", (request) => {
    if (requestCards.has(request.id)) return;
    const card = h("div", { class: "cli-request", style: "padding:10px;border:1px solid #F5A524;border-radius:10px;margin:6px 0" },
      h("strong", { text: t("{provider} needs your answer", { provider: request.provider }) }));
    const fields = new Map<string, HTMLInputElement>();
    if (request.kind === "question") {
      for (const question of request.questions ?? []) {
        const input = h("input", { class: "chat-input", type: question.isSecret ? "password" : "text", autocomplete: "off" }) as HTMLInputElement;
        fields.set(question.id, input);
        card.append(h("label", { text: question.question }), input);
        for (const option of question.options ?? []) {
          card.append(h("button", { text: option.label, onclick: () => { input.value = option.label; } }));
        }
      }
    } else { card.append(h("pre", { text: request.detail, style: "white-space:pre-wrap;max-height:80px;overflow:auto" })); }
    const reply = (allow: boolean) => {
      const answers = Object.fromEntries([...fields].map(([id, input]) => [id, allow ? [input.value] : []]));
      void Bridge.cliAgentAnswer(request.id, { allow, answers }).then(() => {
        card.remove(); requestCards.delete(request.id);
      });
    };
    card.append(
      h("button", { class: "cli-allow", text: request.kind === "question" ? t("Send") : t("Allow once"), onclick: () => reply(true) }),
      h("button", { class: "cli-deny", text: t("Deny"), onclick: () => reply(false) }),
    );
    requestCards.set(request.id, card);
    card.dataset.provider = request.provider.toLowerCase();
    card.hidden = card.dataset.provider !== State.chatProvider;
    requests.append(card);
    onHeightChange();
  });
  void onEvent<{ id: string }>("agent-request-ended", ({ id }) => {
    requestCards.get(id)?.remove(); requestCards.delete(id);
  });

  const el = h("div", { class: "view" }, h("div", { class: "card wash chat-card" }, body));
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;
  let renderedProvider = "";
  const drafts = new Map<string, string>();
  let sendingProvider = "";
  // A local model answers token by token: where its text so far is shown.
  let live: HTMLElement | null = null;

  function drawModelButton() {
    const p = providerDef(State.chatProvider);
    modelDot.style.background = p.accent;
    modelName.textContent = activeModel({ ...State.settings, chatProvider: State.chatProvider }) || (["codex", "antigravity"].includes(p.id) ? p.name : t(STRINGS.noModel));
    modelBtn.classList.toggle("open", picker.isOpen);
    const busyHere = sending && sendingProvider === State.chatProvider;
    modelBtn.disabled = busyHere;
    const cli = ["codex", "antigravity"].includes(State.chatProvider);
    send.title = busyHere && cli ? t("Stop") : t(STRINGS.send);
    send.disabled = sending && (!busyHere || !cli);
    send.textContent = busyHere && cli ? "■" : "↑";
  }

  modelBtn.addEventListener("click", () => {
    if (sending && sendingProvider === State.chatProvider) return;
    if (picker.isOpen) picker.close();
    else picker.open();
  });

  void onEvent<string>("chat-delta", (text) => {
    if (!sending || !text || sendingProvider !== State.chatProvider) return; // nothing visible yet: the dots stay
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
    sendingProvider = State.chatProvider;
    State.chatBusyProvider = sendingProvider;
    const owner = State.tasks.find(t => providerForPill(t.id) === sendingProvider)?.id;
    const notifyReply = (text: string) => {
      if(owner && State.settings.companionMode && (State.mode !== "expanded" || State.focusId !== owner)) void emitToWindow("companions","companions-notice",{key:`chat:${sendingProvider}:${nextId}`,pet:owner,text,urgent:false,view:"prompt"});
    };
    const history = State.chatHistory;
    drawModelButton();
    Sound.play("send");

    history.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const file = State.droppedFile;
    const context: ChatContext | null =
      State.chatHistory.length === 1 && file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      const reply = await Bridge.chatSend(query, context, sendingProvider);
      history.push({ id: nextId++, role: "assistant", content: reply.text });
      if(history.length>100)history.splice(0,history.length-100);
      notifyReply("Your answer is ready.");
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      State.stateOverride = null;
      const message = String(err).replace(/^Error:\s*/, "");
      if (message !== "The CLI request was cancelled.") {
        history.push({id:nextId++,role:"assistant",content:message});
        if(State.chatProvider === sendingProvider) { State.noteMessage = message; State.view = "note"; }
        notifyReply("The chat could not finish. Open it to see the error.");
        Sound.play("error");
      }
    } finally {
      sending = false;
      State.chatBusyProvider = null;
      live = null;
      renderedCount = -1; // the finished answer replaces the streamed one
      drawModelButton();
      State.notify();
      onHeightChange();
      if(State.mode === "expanded" && State.view === "prompt" && State.chatProvider === sendingProvider) input.focus();
    }
  }

  send.addEventListener("click", () => {
    if (sending && sendingProvider === State.chatProvider) void Bridge.chatCancel();
    else if (!sending) void submit();
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
      if (renderedProvider !== State.chatProvider) {
        if (renderedProvider) drafts.set(renderedProvider, input.value);
        input.value = drafts.get(State.chatProvider) ?? "";
        if (State.settings.companionMode && picker.isOpen) picker.close();
        renderedProvider = State.chatProvider; renderedCount = -1; live = null;
      }
      for (const card of requestCards.values()) card.hidden = card.dataset.provider !== State.chatProvider;
      const file = State.droppedFile;
      const wantChip = file?.name ?? "";
      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;
        clear(chipRow);
        if (wantChip) chipRow.append(contextChip(wantChip));
      }

      const thinking = sending && sendingProvider === State.chatProvider;
      const count = State.chatHistory.length + (thinking ? 0.5 : 0);
      if (count !== renderedCount && !live) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
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

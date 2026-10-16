// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView /
// ModelPickerView from IslandViewContent.swift.
//
// Answers are rendered as Markdown (markdown.ts). A local model streams its
// answer: Rust sends `chat-delta` events with the text visible so far. The
// model name above the text field opens the picker: provider chips, then the
// models of the chosen provider, asked for only once it is picked.
// The "Create" chip lists the media models saved in Settings (images, video,
// speech, 3D): their answer is a file, shown as a media card.
//
// One button sends: it is the mic while the field is empty and a
// speech-to-text model is saved (dictation.ts), Send once it holds text.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { renderMarkdown } from "./markdown";
import { startDictation, type Dictation, type DictationPhase } from "./dictation";
import { generatingCard, mediaCard, resetProgress } from "./media";
import { Bridge, onEvent, type ChatContext, type ModelInfo } from "../core/bridge";
import {
  activeModel, creators, pickModel, providerDef, visibleProviders, withModel, type ProviderDef,
} from "../core/providers";
import { Sound } from "../core/sound";
import { State, type ChatMessage, type ModelOutput } from "../core/state";
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
  if (message.content) renderMarkdown(reply, message.content);
  return h(
    "div",
    { class: "chat-row" },
    h(
      "div",
      { class: "answer" },
      message.notice ? h("div", { class: "reply-note", text: message.notice }) : null,
      // A media model may answer with files only.
      message.content ? reply : null,
      ...(message.media ?? []).map(mediaCard),
    ),
  );
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

const IMAGE_FILE = /\.(png|jpe?g|gif|webp)$/i;

/** The saved media model in use on the "Create" chip, if that is the provider. */
function creator() {
  if (State.settings.chatProvider !== "media") return null;
  return creators(State.settings).find((m) => m.id === activeModel(State.settings)) ?? null;
}

/** What the next answer will be: text, or a file of this kind. */
function making(): ModelOutput | "text" {
  return creator()?.output ?? "text";
}

/** The model button's words: a media model by its name, any other by its id. */
function modelLabel(): string {
  if (State.settings.chatProvider === "media") {
    const m = creator();
    return m ? `${m.label || m.model} · ${m.output}` : t(STRINGS.noModel);
  }
  return activeModel(State.settings) || t(STRINGS.noModel);
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
    // The media models are the ones saved in Settings: nothing to ask anyone.
    if (p.id === "media") {
      const saved = creators(State.settings).map((m) => ({ id: m.id, label: `${m.label || m.model} · ${m.output}` }));
      if (saved.length === 0) {
        status("No media model yet: add one in Settings → Media and voice models.", true);
        return;
      }
      const keep = pickModel(p, saved.map((m) => m.id), activeModel(State.settings));
      if (keep && keep !== activeModel(State.settings)) {
        State.settings = withModel(State.settings, p.id, keep);
        saveSettings();
        onChange();
      }
      drawModels(p, saved);
      return;
    }
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
  const modelRow = h("div", { class: "model-row" }, modelBtn);

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
  // A local model answers token by token: where its text so far is shown.
  let live: HTMLElement | null = null;
  /** What the request in flight makes; anything but text shows the "making it" card. */
  let inFlight: ModelOutput | "text" = "text";

  function drawModelButton() {
    const p = providerDef(State.settings.chatProvider);
    modelDot.style.background = p.accent;
    modelName.textContent = modelLabel();
    modelBtn.classList.toggle("open", picker.isOpen);
    modelBtn.disabled = sending;
  }

  modelBtn.addEventListener("click", () => {
    if (sending) return;
    if (picker.isOpen) picker.close();
    else picker.open();
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

  // ── The mic ─────────────────────────────────────────────────────────────────

  let dictation: Dictation | null = null;
  let micPhase: DictationPhase | null = null;
  /** The prompt in flight was spoken: with "Keep the mic on", listen again after the reply. */
  let spoken = false;
  let opening = false;
  // A hidden page never keeps listening (besides the on-screen check below).
  document.addEventListener?.("visibilitychange", () => {
    if (document.hidden) dictation?.cancel();
  });
  const sttModel = () => (State.settings.models ?? []).find((m) => m.output === "stt") ?? null;
  const chatOnScreen = () => State.mode === "expanded" && State.view === "prompt";
  const micFailed = (message: string) => {
    State.noteMessage = message;
    State.view = "note";
    Sound.play("error");
    State.notify();
  };

  async function startMic(rearmed = false) {
    if (dictation || opening || sending) return;
    input.value = "";
    opening = true;
    try {
      dictation = await startDictation({
        // Hands-free waits longer for the next question, but never forever.
        idleMs: rearmed ? 30_000 : 8_000,
        onText(text) {
          input.value = text;
          input.scrollLeft = input.scrollWidth;
        },
        onLevel(level) {
          send.style.setProperty("--level", level.toFixed(2));
          // The island closed or moved on: stop listening.
          if (!chatOnScreen()) dictation?.cancel();
        },
        onPhase(phase) {
          micPhase = phase;
          drawButton();
        },
      });
    } catch {
      micFailed("Coucou can't use the microphone: it's blocked, or there isn't one.");
      return;
    } finally {
      opening = false;
    }
    Sound.play("peek");
    drawButton();
    let text = "";
    try {
      text = await dictation.done;
    } catch (err) {
      micFailed(String(err).replace(/^Error:\s*/, ""));
    }
    dictation = null;
    micPhase = null;
    send.style.removeProperty("--level");
    if (text && chatOnScreen()) {
      input.value = text;
      spoken = true;
      void submit();
    } else {
      input.value = "";
      if (chatOnScreen()) Sound.play("blip");
    }
    State.notify();
  }

  /** The one button's face: mic, listening (with the level), transcribing, or Send. */
  function drawButton() {
    const mic = !!dictation || (!input.value?.trim() && !!sttModel() && making() !== "3d");
    const face = !mic ? "send" : micPhase ?? "mic";
    input.readOnly = !!dictation;
    if (send.dataset.face === face) return;
    send.dataset.face = face;
    send.classList.toggle("mic", mic);
    send.classList.toggle("rec", face === "listening");
    send.classList.toggle("busy", face === "transcribing");
    send.replaceChildren(svg(mic ? ICONS.mic : ICONS.arrowUp, mic ? 13 : 11));
    const stt = sttModel();
    send.title = {
      send: t(STRINGS.send),
      mic: `Speak instead of typing (${stt?.label || stt?.model || "speech to text"})`,
      listening: "Listening: click to send now, Esc to cancel",
      transcribing: "Writing down what you said… Esc to cancel",
    }[face];
  }

  // ── Sending ─────────────────────────────────────────────────────────────────

  async function submit() {
    // A picture-to-3D model needs no words: the picture is the prompt.
    const query = input.value.trim() || (making() === "3d" ? "3D model" : "");
    if (!query || sending) return;
    if (picker.isOpen) picker.close();
    const wasSpoken = spoken;
    spoken = false;
    input.value = "";
    sending = true;
    inFlight = making();
    resetProgress();
    drawModelButton();
    Sound.play("send");

    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const file = State.droppedFile;
    // A picture-to-3D model works from the dropped picture on every turn.
    const pictureTo3d = inFlight === "3d" && !!file && IMAGE_FILE.test(file.path);
    const context: ChatContext | null =
      (State.chatHistory.length === 1 || pictureTo3d) && file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      const reply = await Bridge.chatSend(query, context);
      State.chatHistory.push({
        id: nextId++, role: "assistant", content: reply.text, notice: reply.notice ?? null, media: reply.media ?? [],
      });
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
      // Hands-free: the reply is in, listen for the next question.
      if (wasSpoken && State.settings.keepMicOn && chatOnScreen() && sttModel()) void startMic(true);
    }
  }

  send.addEventListener("click", () => {
    if (dictation) dictation.finish();
    else if (send.dataset.face === "mic") void startMic();
    else void submit();
  });
  input.addEventListener("input", drawButton);
  input.addEventListener("keydown", (e) => {
    const key = (e as KeyboardEvent).key;
    if (dictation && (key === "Enter" || key === "Escape")) {
      e.preventDefault();
      e.stopPropagation();
      if (key === "Enter") dictation.finish();
      else dictation.cancel();
      return;
    }
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
        if (thinking) log.append(inFlight === "text" ? typingDots() : generatingCard(inFlight));
        log.scrollTop = log.scrollHeight;
      }

      // Leaving the chat folds the picker away.
      if (State.view !== "prompt" && picker.isOpen) picker.close();
      drawModelButton();

      const hints: Record<string, string> = {
        image: "Describe an image…",
        video: "Describe a video…",
        audio: "Text to speak…",
        "3d": State.droppedFile ? "Press Enter to make it 3D…" : "Drop a picture to make it 3D…",
      };
      const output = making();
      input.placeholder =
        output !== "text"
          ? hints[output] ?? ""
          : t(State.chatHistory.length === 0 ? STRINGS.placeholderFirst : STRINGS.placeholderNext);
      if (micPhase === "listening") input.placeholder = t("Listening…");
      input.disabled = sending;
      drawButton();
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}

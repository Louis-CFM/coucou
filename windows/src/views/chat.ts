// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, onEvent, type ChatContext } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type ChatMessage } from "../core/state";
import type { ViewHost } from "./views";

let nextId = 1;

function bubble(message: ChatMessage): HTMLElement {
  if (message.role === "user") {
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "bubble", text: message.content }),
    );
  }
  return h("div", { class: "chat-row" }, h("div", { class: "reply", text: message.content }));
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

/** Only offer providers that are actually configured — Claude always (even
 * without a key yet, same as before this existed), local ones once a URL and
 * model have been picked in Settings. */
function configuredProviders(): { value: string; label: string }[] {
  const list: { value: string; label: string }[] = [{ value: "anthropic", label: "Claude" }];
  if (State.settings.ollamaUrl && State.settings.ollamaModel) {
    list.push({ value: "ollama", label: `Ollama · ${State.settings.ollamaModel}` });
  }
  if (State.settings.lmstudioUrl && State.settings.lmstudioModel) {
    list.push({ value: "lmstudio", label: `LM Studio · ${State.settings.lmstudioModel}` });
  }
  return list;
}

export function buildPrompt(onHeightChange: () => void): ViewHost {
  const chipRow = h("div", { class: "chip-row" });
  const providerSelect = h("select", { class: "chat-provider-select" }) as HTMLSelectElement;
  providerSelect.addEventListener("change", () => {
    State.settings.chatProvider = providerSelect.value as typeof State.settings.chatProvider;
    void Bridge.saveSettings(State.settings);
  });
  const log = h("div", { class: "chat-log" });
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Ask me anything…",
    spellcheck: "false",
  }) as HTMLInputElement;
  const send = h("button", { class: "send-btn", title: "Send" }, svg(ICONS.arrowUp, 11));
  const bar = h("div", { class: "chat-bar" }, input, send);

  const providerRow = h("div", { class: "chat-provider-row" }, providerSelect);

  const el = h(
    "div",
    { class: "view" },
    h(
      "div",
      { class: "card wash chat-card" },
      h("div", { class: "chat-body" }, providerRow, chipRow, log, bar),
    ),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;
  // Ollama/LM Studio stream their reply as "chat-token" events while
  // chat_send is still in flight; Claude just resolves with the full text.
  // `liveId` names the placeholder bubble a stream is filling in, and
  // `streamTick` forces a re-render on every token even though the chat
  // history's own length doesn't change while it fills in.
  let liveId: number | null = null;
  let streamTick = 0;
  let lastStreamTick = -1;

  void onEvent<string>("chat-token", (delta) => {
    if (liveId == null) return;
    const msg = State.chatHistory.find((m) => m.id === liveId);
    if (!msg) return;
    msg.content += delta;
    streamTick++;
    State.notify();
    onHeightChange();
  });

  async function submit() {
    const query = input.value.trim();
    if (!query || sending) return;
    input.value = "";
    sending = true;
    Sound.play("send");

    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    const streaming = State.settings.chatProvider !== "anthropic";
    liveId = streaming ? nextId++ : null;
    if (liveId != null) State.chatHistory.push({ id: liveId, role: "assistant", content: "" });
    State.notify();
    onHeightChange();

    const file = State.droppedFile;
    const context: ChatContext | null =
      State.chatHistory.length === 1 && file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      const reply = await Bridge.chatSend(query, context);
      if (liveId != null) {
        const msg = State.chatHistory.find((m) => m.id === liveId);
        if (msg) msg.content = reply.text;
      } else {
        State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text });
      }
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      if (liveId != null) State.chatHistory = State.chatHistory.filter((m) => m.id !== liveId);
      State.stateOverride = null;
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";
      Sound.play("error");
    } finally {
      liveId = null;
      sending = false;
      State.notify();
      onHeightChange();
      input.focus();
    }
  }

  send.addEventListener("click", () => void submit());
  input.addEventListener("keydown", (e) => {
    if ((e as KeyboardEvent).key === "Enter") {
      e.preventDefault();
      void submit();
    }
    e.stopPropagation(); // Escape closes the island, not the chat
  });

  return {
    el,
    sync() {
      const providerKey =
        `${State.settings.chatProvider}|${State.settings.ollamaUrl}|${State.settings.ollamaModel}` +
        `|${State.settings.lmstudioUrl}|${State.settings.lmstudioModel}`;
      if (providerRow.dataset.key !== providerKey) {
        providerRow.dataset.key = providerKey;
        const options = configuredProviders();
        clear(providerSelect);
        for (const o of options) providerSelect.append(h("option", { value: o.value, text: o.label }));
        providerSelect.value = options.some((o) => o.value === State.settings.chatProvider)
          ? State.settings.chatProvider
          : "anthropic";
        // More than one choice makes this worth showing; with just Claude,
        // it would be a dropdown offering nothing to switch to.
        providerRow.style.display = options.length > 1 ? "" : "none";
      }

      const file = State.droppedFile;
      const wantChip = file?.name ?? "";
      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;
        clear(chipRow);
        if (wantChip) chipRow.append(contextChip(wantChip));
      }

      const thinking = State.stateOverride === "thinking";
      const count = State.chatHistory.length + (thinking ? 0.5 : 0);
      if (count !== renderedCount || streamTick !== lastStreamTick) {
        renderedCount = count;
        lastStreamTick = streamTick;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
      }

      input.placeholder = State.chatHistory.length === 0 ? "Ask me anything…" : "Continue…";
      input.disabled = sending;
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}

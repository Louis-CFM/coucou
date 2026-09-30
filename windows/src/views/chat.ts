// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext } from "../core/bridge";
import { reconcileChatSession, waitForChatSessionReady } from "../core/chat-session";
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

export function buildPrompt(onHeightChange: () => void): ViewHost {
  const chipRow = h("div", { class: "chip-row" });
  const log = h("div", { class: "chat-log" });
  const provider = h("select", { class: "chat-provider", "aria-label": "Chat provider" }) as HTMLSelectElement;
  provider.append(
    h("option", { value: "claude", text: "Claude" }),
    h("option", { value: "codex", text: "Codex" }),
  );
  const codexModel = h("input", {
    type: "text",
    class: "chat-model",
    placeholder: "CLI default model",
    title: "Optional Codex model override. Leave empty to use the Codex CLI default.",
    "aria-label": "Codex model override",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;
  const controls = h("div", { class: "chat-controls" },
    h("span", { class: "chat-provider-label", text: "Chat with" }), provider, codexModel,
  );
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Ask me anything…",
    spellcheck: "false",
  }) as HTMLInputElement;
  const send = h("button", { class: "send-btn", title: "Send" }, svg(ICONS.arrowUp, 11));
  const bar = h("div", { class: "chat-bar" }, input, send);

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, controls, chipRow, log, bar)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let activeGeneration: number | null = null;
  let renderedCount = -1;

  function currentModel(providerName: "claude" | "codex"): string {
    return providerName === "codex" ? State.settings.codexModel : State.settings.model;
  }

  function changeConfig(providerName: "claude" | "codex", modelOverride = State.settings.codexModel) {
    State.settings.chatProvider = providerName;
    State.settings.codexModel = modelOverride.trim();
    reconcileChatSession(true);
  }

  provider.addEventListener("change", () => {
    changeConfig(provider.value as "claude" | "codex");
  });
  codexModel.addEventListener("change", () => {
    changeConfig(State.settings.chatProvider, codexModel.value);
  });

  async function submit() {
    const query = input.value.trim();
    reconcileChatSession(false, Boolean(query));
    const generation = State.chatGeneration;
    if (!query || activeGeneration === generation) return;
    input.value = "";
    activeGeneration = generation;
    const chatProvider = State.settings.chatProvider;
    const model = currentModel(chatProvider);
    Sound.play("send");

    const userMessage = { id: nextId++, role: "user" as const, content: query };
    State.chatHistory.push(userMessage);
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const file = State.droppedFile;
    const context: ChatContext | null =
      State.chatHistory.length === 1 && file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      await waitForChatSessionReady();
      if (generation !== State.chatGeneration) return;
      const reply = await Bridge.chatSend(query, context, chatProvider, model);
      if (generation !== State.chatGeneration) return;
      State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text });
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      if (generation !== State.chatGeneration) return;
      State.chatHistory = State.chatHistory.filter((message) => message.id !== userMessage.id);
      State.stateOverride = null;
      const detail = String(err).replace(/^Error:\s*/, "");
      State.noteMessage = chatProvider === "codex" && context?.kind === "file" && /\.pdf$/i.test(context.name)
        ? "Codex chat does not support PDF files yet. Try a text file, an image, or paste the relevant text."
        : detail;
      State.view = "note";
      Sound.play("error");
    } finally {
      if (activeGeneration === generation) activeGeneration = null;
      if (generation === State.chatGeneration) {
        State.notify();
        onHeightChange();
        input.focus();
      }
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
      reconcileChatSession();
      if (document.activeElement !== provider) provider.value = State.settings.chatProvider;
      if (document.activeElement !== codexModel) codexModel.value = State.settings.codexModel;
      codexModel.style.display = State.settings.chatProvider === "codex" ? "" : "none";
      const file = State.droppedFile;
      const wantChip = file?.name ?? "";
      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;
        clear(chipRow);
        if (wantChip) chipRow.append(contextChip(wantChip));
      }

      const thinking = State.stateOverride === "thinking";
      const count = State.chatHistory.length + (thinking ? 0.5 : 0);
      if (count !== renderedCount) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
      }

      input.placeholder = State.chatHistory.length === 0 ? "Ask me anything…" : "Continue…";
      input.disabled = activeGeneration === State.chatGeneration;
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}

// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { chooseCursorProject } from "../island/cursor";
import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext } from "../core/bridge";
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
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Ask me anything…",
    spellcheck: "false",
  }) as HTMLInputElement;
  const target = h("button", { class: "chat-target", title: "Talk to Cursor", text: "Cursor" });
  const mode = h("button", { class: "chat-target hidden", title: "Agent can edit the project", text: "Agent" });
  const project = h("button", {
    class: "chat-target hidden",
    title: "Choose the project, Cursor can stay closed",
    text: "Folder",
  });
  const send = h("button", { class: "send-btn", title: "Send" }, svg(ICONS.arrowUp, 11));
  const bar = h("div", { class: "chat-bar" }, target, mode, project, input, send);

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, chipRow, log, bar)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;

  function useCursor() {
    State.chatTarget = State.chatTarget === "cursor" ? "claude" : "cursor";
    State.chatHistory = [];
    void Bridge.chatReset();
    void Bridge.cursorChatReset();
    State.notify();
    onHeightChange();
    input.focus();
  }

  target.addEventListener("click", () => {
    if (!sending) useCursor();
  });

  mode.addEventListener("click", () => {
    if (sending || State.chatTarget !== "cursor") return;
    State.cursorMode = State.cursorMode === "agent" ? "ask" : "agent";
    State.notify();
    input.focus();
  });

  project.addEventListener("click", () => {
    if (!sending) void chooseCursorProject();
  });

  async function submit() {
    const query = input.value.trim();
    if (!query || sending) return;
    input.value = "";
    sending = true;
    Sound.play("send");

    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const file = State.droppedFile;
    const first = State.chatHistory.length === 1;
    const context: ChatContext | null =
      first && file ? { kind: "file", name: file.name, path: file.path } : null;
    const cursor = State.chatTarget === "cursor";
    const cwd = State.tasks.find((t) => t.id === "integration_cursor")?.sessionCwd
      ?? State.settings.cursorProject;
    const asked = cursor && first && file ? `${query}\n\nAttached file: ${file.path}` : query;

    try {
      const reply = cursor
        ? await Bridge.cursorChatSend(asked, cwd, State.cursorMode)
        : await Bridge.chatSend(query, context);
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

      const cursorOn = State.chatTarget === "cursor";
      const editing = State.cursorMode === "agent";
      target.classList.toggle("on", cursorOn);
      target.textContent = cursorOn ? "Cursor" : "Claude";
      target.title = cursorOn ? "Talking to Cursor — click for Claude" : "Talk to Cursor";
      mode.classList.toggle("hidden", !cursorOn);
      mode.classList.toggle("on", cursorOn && editing);
      mode.textContent = editing ? "Agent" : "Ask";
      mode.title = editing ? "Agent can edit the project — click for Ask" : "Ask only answers — click for Agent";
      const folder = State.tasks.find((t) => t.id === "integration_cursor")?.sessionCwd
        ?? State.settings.cursorProject;
      const base = folder?.split(/[/\\]/).filter(Boolean).pop() ?? "";
      project.classList.toggle("hidden", !cursorOn);
      project.classList.toggle("on", Boolean(base));
      project.textContent = base ? (base.length > 14 ? `${base.slice(0, 13)}…` : base) : "Folder";
      project.title = folder ?? "Choose the project. Cursor can stay closed.";
      input.placeholder = State.chatHistory.length === 0
        ? (cursorOn ? (editing ? "Tell Cursor…" : "Ask Cursor…") : "Ask me anything…")
        : "Continue…";
      input.disabled = sending;
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}

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

  return h(
    "div",
    { class: "chat-row" },
    h("div", { class: "reply", text: message.content }),
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
  const chip = h(
    "div",
    { class: "chip" },
    h("i", { class: "chip-dot" }),
    h("span", { text: label }),
  );

  requestAnimationFrame(() => chip.classList.add("settled"));

  return chip;
}

export function buildPrompt(onHeightChange: () => void): ViewHost {
  const chipRow = h("div", { class: "chip-row" });

  const log = h("div", {
    class: "chat-log",
  });

  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Ask me anything…",
    spellcheck: "false",
  }) as HTMLInputElement;

  const send = h(
    "button",
    {
      class: "send-btn",
      title: "Send",
      "aria-label": "Send",
    },
    svg(ICONS.arrowUp, 11),
  );

  const reset = h(
    "button",
    {
      class: "chat-reset-btn",
      title: "Start a new chat",
      "aria-label": "Start a new chat",
    },
    svg(ICONS.reset, 20),
  );

  const bar = h(
    "div",
    { class: "chat-bar" },
    input,
    reset,
    send,
  );

  const el = h(
    "div",
    { class: "view" },
    h(
      "div",
      { class: "card wash chat-card" },
      h(
        "div",
        { class: "chat-body" },
        chipRow,
        log,
        bar,
      ),
    ),
  );

  (
    el.querySelector(".card") as HTMLElement
  ).style.setProperty(
    "--wash",
    "rgba(99,102,241,0.5)",
  );

  let sending = false;
  let renderedKey = "";

  async function resetChat() {
    if (sending) return;

    try {
      await Bridge.chatReset();

      State.chatHistory.length = 0;
      State.droppedFile = null;
      State.stateOverride = null;
      State.noteMessage = null;

      Sound.play("finish");

      State.notify();
      onHeightChange();

      input.value = "";
      input.placeholder = "Ask me anything…";
      input.focus();
    } catch (err) {
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";

      Sound.play("error");

      State.notify();
      onHeightChange();
    }
  }

  async function submitStream() {
    const query = input.value.trim();

    if (!query || sending) return;

    const isFirstTurn = State.chatHistory.length === 0;

    input.value = "";
    sending = true;

    Sound.play("send");

    const requestId = crypto.randomUUID();

    State.chatHistory.push({
      id: nextId++,
      role: "user",
      content: query,
    });

    const assistantId = nextId++;

    State.chatHistory.push({
      id: assistantId,
      role: "assistant",
      content: "",
    });

    State.stateOverride = "thinking";

    State.notify();
    onHeightChange();

    const file = State.droppedFile;

    const context: ChatContext | null =
      isFirstTurn && file
        ? {
            kind: "file",
            name: file.name,
            path: file.path,
          }
        : null;

    let unlisten: (() => void) | null = null;

    try {
      unlisten = await Bridge.listenChatStream((chunk) => {
        // Ignore events belonging to another request.
        if (chunk.requestId !== requestId) {
          return;
        }

        const message = State.chatHistory.find(
          (item) => item.id === assistantId,
        );

        if (!message || message.role !== "assistant") {
          return;
        }

        /*
         * The Rust side sends a terminal event for stream errors.
         *
         * Keep any partial response visible. The error view explains
         * what happened, while the partial text remains in the chat UI.
         */
        if (chunk.error) {
          State.stateOverride = null;
          State.noteMessage = chunk.error;
          State.view = "note";

          State.notify();
          onHeightChange();

          return;
        }

        /*
         * Append every streamed token/delta to the assistant message.
         */
        if (chunk.delta) {
          message.content += chunk.delta;

          State.stateOverride = null;

          State.notify();
          onHeightChange();
        }

        /*
         * Successful terminal event.
         */
        if (chunk.done) {
          State.stateOverride = null;

          Sound.play("finish");

          State.notify();
          onHeightChange();
        }
      });

      await Bridge.chatSendStream(
        requestId,
        query,
        context,
      );
    } catch (err) {
      /*
       * If the request failed before any assistant text arrived,
       * remove the empty assistant bubble.
       *
       * If partial text already exists, keep it visible.
       */
      const message = State.chatHistory.find(
        (item) => item.id === assistantId,
      );

      if (message?.role === "assistant" && !message.content) {
        const index = State.chatHistory.findIndex(
          (item) => item.id === assistantId,
        );

        if (index !== -1) {
          State.chatHistory.splice(index, 1);
        }
      }

      State.stateOverride = null;

      State.noteMessage = String(err).replace(
        /^Error:\s*/,
        "",
      );

      State.view = "note";

      Sound.play("error");

      State.notify();
      onHeightChange();
    } finally {
      unlisten?.();

      sending = false;

      State.notify();
      onHeightChange();

      input.focus();
    }
  }

  reset.addEventListener("click", () => {
    void resetChat();
  });

  send.addEventListener("click", () => {
    void submitStream();
  });

  input.addEventListener("keydown", (e) => {
    if ((e as KeyboardEvent).key === "Enter") {
      e.preventDefault();
      void submitStream();
    }

    // Escape closes the island, not the chat.
    e.stopPropagation();
  });

  return {
    el,

    sync() {
      const file = State.droppedFile;
      const wantChip = file?.name ?? "";

      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;

        clear(chipRow);

        if (wantChip) {
          chipRow.append(contextChip(wantChip));
        }
      }

      const thinking =
        State.stateOverride === "thinking";

      /*
       * Content changes during streaming, so chatHistory.length alone
       * cannot determine whether the DOM needs updating.
       *
       * The content itself is part of the render key.
       */
      const renderKey = [
        thinking ? "thinking" : "idle",

        ...State.chatHistory.map(
          (message) =>
            `${message.id}:${message.role}:${message.content.length}:${message.content}`,
        ),
      ].join("|");

      if (renderKey !== renderedKey) {
        renderedKey = renderKey;

        clear(log);

        for (const message of State.chatHistory) {
          log.append(bubble(message));
        }

        if (thinking) {
          log.append(typingDots());
        }

        requestAnimationFrame(() => {
          log.scrollTop = log.scrollHeight;
        });
      }

      input.placeholder =
        State.chatHistory.length === 0
          ? "Ask me anything…"
          : "Continue…";

      input.disabled = sending;
      reset.disabled = sending;
    },

    focus() {
      input.focus();
      input.select();
    },
  };
}
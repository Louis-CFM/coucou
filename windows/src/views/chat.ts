// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

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

/**
 * The active gateway, shown above the input and clickable to switch — the same
 * affordance the macOS build uses: the model name above the chat box opens the
 * provider list. Only routable providers are offered; the ones Coucou cannot drive are
 * listed with their reason so the list reads as a fact, not an omission.
 */
async function providerPicker(
  onPick: (id: string) => void,
  close: () => void,
): Promise<HTMLElement> {
  const rows = (await Bridge.chatProviders()) ?? [];
  const list = h("div", { class: "provider-list" });

  for (const p of rows) {
    if (p.unavailable !== null) continue;
    const selected = p.id === State.settings.chatProvider;
    const item = h(
      "button",
      {
        class: "provider-item",
        style: "display:flex;align-items:center;gap:8px;width:100%;text-align:left;" +
          "border:0;background:transparent;color:inherit;padding:5px 7px;cursor:pointer;border-radius:7px;",
      },
      h("i", {
        style: `width:7px;height:7px;border-radius:50%;flex:0 0 auto;` +
          `background:${p.keyPresent || p.keyless ? p.accent : "transparent"};` +
          `box-shadow:inset 0 0 0 1px ${p.accent};`,
      }),
      h("span", { style: "flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis", text: p.label }),
      p.keyless
        ? h("span", { class: "hint", text: "local" })
        : p.keyPresent
          ? null
          : h("span", { class: "hint", text: "no key" }),
      selected ? h("span", { class: "hint", text: "✓" }) : null,
    );
    item.addEventListener("click", () => {
      onPick(p.id);
      close();
    });
    list.append(item);
  }

  return h(
    "div",
    {
      style: "position:absolute;left:0;right:0;bottom:100%;margin-bottom:6px;z-index:20;" +
        "background:rgba(22,22,26,0.97);border:1px solid #2a2a30;border-radius:10px;" +
        "padding:5px;max-height:220px;overflow-y:auto;box-shadow:0 8px 28px rgba(0,0,0,0.5);",
    },
    list,
  );
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
  const send = h("button", { class: "send-btn", title: "Send" }, svg(ICONS.arrowUp, 11));
  const bar = h("div", { class: "chat-bar" }, input, send);

  // The gateway chip sits above the bar and opens the provider list. It re-labels
  // itself from the active provider's own model, so switching provider and switching
  // model are both visible from the same place.
  const providerChip = h("button", {
    class: "provider-chip",
    title: "Switch provider",
    style: "align-self:flex-start;display:flex;align-items:center;gap:6px;" +
      "background:transparent;border:1px solid #2a2a30;border-radius:999px;" +
      "color:inherit;font:inherit;font-size:11px;padding:2px 9px;cursor:pointer;",
  });
  let popover: HTMLElement | null = null;

  function closePicker() {
    popover?.remove();
    popover = null;
  }

  providerChip.addEventListener("click", async (e) => {
    e.stopPropagation();
    if (popover) {
      closePicker();
      return;
    }
    popover = await providerPicker((id) => {
      State.settings.chatProvider = id;
      State.notify();
      void Bridge.saveSettings(State.settings);
    }, closePicker);
    bar.style.position = "relative";
    bar.append(popover);
  });

  const wrap = h("div", {
    style: "display:flex;flex-direction:column;gap:6px;position:relative",
  });
  wrap.append(providerChip, bar);

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, chipRow, log, wrap)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;
  let renderedProvider = State.settings.chatProvider;
  let providerLabel = "";

  /** Reads the active provider's row so the chip shows its real label and model. */
  async function labelProvider() {
    const rows = (await Bridge.chatProviders()) ?? [];
    const id = State.settings.chatProvider;
    const p = rows.find((r) => r.id === id);
    const model = p ? (State.settings.providerModels[p.id] ?? p.defaultModel) : "";
    providerLabel = p ? `${p.label} · ${model}` : id;
  }
  void labelProvider();

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

      // Switching provider swaps the whole thread, so both the label and the rendered
      // messages are keyed on the provider id — a length comparison alone would miss
      // two threads that happen to be the same size.
      if (renderedProvider !== State.settings.chatProvider) {
        renderedProvider = State.settings.chatProvider;
        renderedCount = -1;
        void labelProvider();
      }
      providerChip.textContent = providerLabel || State.settings.chatProvider;

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
      input.disabled = sending;
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}

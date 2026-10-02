// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext } from "../core/bridge";
import { Sound } from "../core/sound";
import { codeBlock, renderMarkdown } from "./markdown";
import { State, type ChatMessage } from "../core/state";
import type { ViewHost } from "./views";

let nextId = 1;

function bubble(message: ChatMessage): HTMLElement {
  if (message.role === "user") {
    const a = message.attachment;
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "user-turn" },
        // The dropped code file, as the model got it: Markdown code.
        a ? codeBlock(a.text, a.lang, `${a.name} · ${a.text.split("\n").length} lines`) : null,
        h("div", { class: "bubble", text: message.content }),
      ),
    );
  }
  const reply = h("div", { class: "reply md" });
  reply.append(renderMarkdown(message.content));
  return h(
    "div",
    { class: "chat-row" },
    h("div", {},
      message.notice ? h("div", { class: "reply-note", text: message.notice }) : null,
      reply,
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

/** The coloured chip showing what the question is about (a dropped file), with
 *  an x to drop it. */
function contextChip(label: string, onRemove: () => void): HTMLElement {
  const remove = h("button", { class: "chip-x", title: "Remove" }, svg(ICONS.xmark, 9));
  remove.addEventListener("click", (e) => {
    e.stopPropagation();
    onRemove();
  });
  const chip = h(
    "div",
    { class: "chip" },
    h("i", { class: "chip-dot" }),
    h("span", { text: label }),
    remove,
  );
  requestAnimationFrame(() => chip.classList.add("settled"));
  return chip;
}

const IMAGE_FILE = /\.(png|jpe?g|gif|webp)$/i;
/** The error chat_send reports when a text-only model refuses an image. */
const IMAGES_UNSUPPORTED = "IMAGES_UNSUPPORTED";

function activeModel() {
  const models = State.settings.models ?? [];
  return models.find((m) => m.id === State.settings.activeModel) ?? models[0] ?? null;
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

  // Model picker, next to Send (like the Claude website).
  const modelBtn = h("button", { class: "model-btn", title: "Choose the model" });
  const modelMenu = h("div", { class: "model-menu" });
  const picker = h("div", { class: "model-picker" }, modelMenu, modelBtn);
  let menuOpen = false;
  const setMenu = (open: boolean) => {
    menuOpen = open;
    modelMenu.classList.toggle("open", open);
    if (open) drawMenu();
  };
  function drawMenu() {
    clear(modelMenu);
    for (const m of State.settings.models ?? []) {
      const item = h(
        "button",
        { class: m.id === activeModel()?.id ? "model-item on" : "model-item" },
        h("span", { class: "model-name", text: m.label || m.model }),
        m.vision === true ? h("span", { class: "model-tag eye", title: "Sees images" }, svg(ICONS.eye, 10)) : null,
        m.vision === false ? h("span", { class: "model-tag", text: "text" }) : null,
      );
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        State.settings.activeModel = m.id;
        void Bridge.saveSettings(State.settings);
        setMenu(false);
        askImage = askImage && !(m.vision === true || m.kind === "claude") ? askImage : false;
        State.notify();
        input.focus();
      });
      modelMenu.append(item);
    }
    const manage = h("button", { class: "model-item manage", text: "Manage models…" });
    manage.addEventListener("click", (e) => {
      e.stopPropagation();
      setMenu(false);
      void Bridge.openSettingsWindow();
    });
    modelMenu.append(manage);
  }
  modelBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    setMenu(!menuOpen);
  });
  document.addEventListener("click", () => menuOpen && setMenu(false));

  // "This model can't see images": asked instead of wasting a request.
  let askImage = false;
  let pendingQuery = "";
  const askText = h("span", {});
  const sendTextOnly = h("button", { class: "btn primary small", text: "Send without image" });
  const switchModel = h("button", { class: "btn secondary small", text: "Switch model" });
  const cancelAsk = h("button", { class: "btn secondary small", text: "Cancel" });
  const ask = h("div", { class: "image-ask" }, askText, h("div", { class: "image-ask-btns" }, sendTextOnly, switchModel, cancelAsk));
  sendTextOnly.addEventListener("click", () => {
    askImage = false;
    input.value = pendingQuery;
    void submit(true);
  });
  switchModel.addEventListener("click", (e) => {
    e.stopPropagation();
    setMenu(true);
  });
  cancelAsk.addEventListener("click", () => {
    askImage = false;
    input.value = pendingQuery;
    State.notify();
    onHeightChange();
  });

  const bar = h("div", { class: "chat-bar" }, input, picker, send);

  // Under Mochi: start the conversation over (the dropped file stays attached).
  const clearChat = h("button", { class: "chat-clear", title: "Clear chat" }, svg(ICONS.trash, 11), h("span", { text: "Clear" }));
  clearChat.addEventListener("click", () => {
    if (sending) return;
    State.chatHistory = [];
    void Bridge.chatReset();
    renderedCount = -1;
    State.notify();
    onHeightChange();
    input.focus();
  });

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, clearChat, h("div", { class: "chat-body" }, chipRow, log, ask, bar)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;

  async function submit(textOnly = false) {
    const query = input.value.trim();
    if (!query || sending) return;
    const file = State.droppedFile;
    const firstTurn = State.chatHistory.length === 0;
    const withImage = firstTurn && !!file && IMAGE_FILE.test(file.path) && !textOnly;
    // Known text-only model: ask before sending the image, don't spend a request.
    const model = activeModel();
    if (withImage && model?.vision === false) {
      pendingQuery = query;
      askImage = true;
      State.notify();
      onHeightChange();
      return;
    }
    input.value = "";
    sending = true;
    askImage = false;
    Sound.play("send");

    // A dropped text or code file goes along on the first turn: show it too.
    const attachment =
      firstTurn && file?.path && !IMAGE_FILE.test(file.path) ? await Bridge.readAttachment(file.path) : null;
    State.chatHistory.push({
      id: nextId++,
      role: "user",
      content: query,
      attachment: attachment ? { name: file!.name, ...attachment } : null,
    });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const context: ChatContext | null =
      State.chatHistory.length === 1 && file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      const reply = await Bridge.chatSend(query, context, textOnly);
      State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text, notice: reply.notice });
      // The model ends with how it feels about its answer; the island acts it out.
      if (reply.mood) window.dispatchEvent(new CustomEvent("mochi-mood", { detail: reply.mood }));
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      State.stateOverride = null;
      const message = String(err).replace(/^Error:\s*/, "");
      if (message === IMAGES_UNSUPPORTED) {
        // The model turned the image down: take the question back and ask.
        State.chatHistory.pop();
        pendingQuery = query;
        askImage = true;
        Sound.play("blip");
      } else {
        State.noteMessage = message;
        State.view = "note";
        Sound.play("error");
      }
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
        if (wantChip) {
          chipRow.append(
            contextChip(wantChip, () => {
              State.dropAttachment();
              onHeightChange();
            }),
          );
        }
      }

      clearChat.style.display = State.chatHistory.length ? "" : "none";
      const thinking = State.stateOverride === "thinking";
      const count = State.chatHistory.length + (thinking ? 0.5 : 0);
      if (count !== renderedCount) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
      }

      const name = State.settings.mochiName?.trim() || "me";
      input.placeholder = State.chatHistory.length === 0 ? `Ask ${name} anything…` : "Continue…";
      input.disabled = sending;

      const model = activeModel();
      modelBtn.textContent = `${model?.label || model?.model || "No model"} \u25BE`;
      ask.classList.toggle("open", askImage);
      askText.textContent = `${model?.label || model?.model || "This model"} can't see images.`;
      if (menuOpen) drawMenu();
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}

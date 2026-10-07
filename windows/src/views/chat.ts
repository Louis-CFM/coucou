// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, onEvent, type ChatContext } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type ChatMessage } from "../core/state";
import { actionLine, sessionSnapshot } from "../core/task";
import { modelPicker } from "./chat-model-picker";
import { micControl } from "./mic";
import { insertText } from "../core/voice";
import { nextChatId, publishChat } from "../core/chat-sync";
import { applyPendingMemoryStatus } from "../core/memory-status";
import { chatRenderKey, forgetConfirmationCopy, forgetTurnArgs, memoryStatusText, snapshotForgetConfirmation } from "../memory/controllers";
import { selectionWithinBubble, utf8Span } from "./memory-selection";
import type { ViewHost } from "./views";

let nextId = 1;
/** Rust's reply when the chat was reset while a turn was in flight (claude.rs CLEARED). */
const CHAT_CLEARED = "The chat was cleared.";

function selectedReplySpan(reply: HTMLElement, content: string): { text: string; start: number; end: number } | null {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount !== 1 || !selection.anchorNode || !selection.focusNode) return null;
  const anchor = (selection.anchorNode.nodeType === Node.ELEMENT_NODE ? selection.anchorNode as Element : selection.anchorNode.parentElement)?.closest(".reply") as HTMLElement | null;
  const focus = (selection.focusNode.nodeType === Node.ELEMENT_NODE ? selection.focusNode as Element : selection.focusNode.parentElement)?.closest(".reply") as HTMLElement | null;
  if (!selectionWithinBubble({ anchorBubble: anchor?.dataset.turn ?? null, focusBubble: focus?.dataset.turn ?? null }) || anchor !== reply || focus !== reply) return null;
  const range = selection.getRangeAt(0);
  const prefix = document.createRange();
  prefix.selectNodeContents(reply);
  prefix.setEnd(range.startContainer, range.startOffset);
  const startUtf16 = prefix.toString().length;
  const endUtf16 = startUtf16 + range.toString().length;
  const span = utf8Span(content, startUtf16, endUtf16);
  return span && span.text === selection.toString() ? span : null;
}

function bubble(message: ChatMessage): HTMLElement {
  if (message.role === "action") {
    return h(
      "div",
      { class: "chat-row" },
      h("div", { class: `chat-action ${message.actionKind ?? "ok"}`, text: message.content }),
    );
  }
  if (message.role === "user") {
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "bubble", text: message.content }),
    );
  }
  const reply = h("div", { class: "reply", text: message.content, "data-turn": message.turnId ?? `message-${message.id}` });
  const status = h("span", { class: "memory-action-status", role: "status", "aria-live": "polite", text: memoryStatusText(message.memoryStatus) });
  const remember = h("button", { class: "memory-action", text: "Remember turn" }) as HTMLButtonElement;
  remember.disabled = !message.turnId;
  remember.addEventListener("click", async () => {
    if (!message.turnId) return;
    remember.disabled = true; status.textContent = "Saving…";
    try { await Bridge.rememberTurn(message.turnId); status.textContent = "Memory saved"; }
    catch { status.textContent = "Memory not saved"; }
    finally { remember.disabled = false; }
  });
  const selection = h("button", { class: "memory-action", text: "Remember selection" }) as HTMLButtonElement;
  selection.disabled = !message.turnId;
  selection.addEventListener("click", async () => {
    const span = selectedReplySpan(reply, message.content);
    if (!message.turnId || !span) { status.textContent = "Select text inside this reply first"; return; }
    selection.disabled = true; status.textContent = "Saving selection…";
    try { await Bridge.rememberSelection(message.turnId, span.text, span.start, span.end); status.textContent = "Selection saved"; }
    catch { status.textContent = "Memory not saved"; }
    finally { selection.disabled = false; }
  });
  const forget = h("button", { class: "memory-action", text: "Forget" });
  forget.disabled = !message.turnId;
  forget.addEventListener("click", async () => {
    if (!message.turnId) return;
    forget.disabled = true; status.textContent = "Preparing retirement summary…";
    try {
      const prepared = snapshotForgetConfirmation(await Bridge.prepareForgetTurn(message.turnId));
      if (!window.confirm(forgetConfirmationCopy(prepared))) return;
      status.textContent = "Retiring turn memories…";
      const result = await Bridge.forgetTurn(forgetTurnArgs(prepared).confirmation);
      if (result.discoveryFailures.length || result.failed.length) status.textContent = `Retired ${result.retired.length} of ${result.requested}; some lookups or retirements failed`;
      else if (result.retired.length) status.textContent = `Retired ${result.retired.length} memories`;
      else if (result.documentIds.length) { status.textContent = `No remote IDs found; opening ${result.documentIds.length} document scope${result.documentIds.length === 1 ? "" : "s"}…`; void Bridge.openMemoryWindow({ documentIds: result.documentIds }); }
      else { status.textContent = "No document IDs found; opening text fallback…"; void Bridge.openMemoryWindow({ query: message.content.slice(0, 160) }); }
    } catch { status.textContent = "Memory retirement or discovery failed"; }
    finally { forget.disabled = false; }
  });
  return h("div", { class: "chat-row" }, h("div", { class: "reply-wrap" }, reply, h("div", { class: "memory-actions" }, remember, selection, forget, status)));
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

export interface PromptOptions {
  /** Quick chat window: errors go into the log instead of the island's note view. */
  inlineErrors?: boolean;
}

export interface PromptHost extends ViewHost {
  /** Voice hotkey: start recording, or stop and send. */
  toggleVoice(): void;
  /** Window hidden or view left: drop a recording in progress. */
  cancelVoice(): void;
}

export function buildPrompt(onHeightChange: () => void, options: PromptOptions = {}): PromptHost {
  const chipRow = h("div", { class: "chip-row" });
  const log = h("div", { class: "chat-log" });
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Ask me anything…",
    spellcheck: "false",
  }) as HTMLInputElement;
  const send = h("button", { class: "send-btn", title: "Send", "aria-label": "Send message" }, svg(ICONS.arrowUp, 11));
  const privacy = h("button", { class: "private-chat-toggle", title: "Session-only private chat", "aria-pressed": "false", text: "Private off" });
  privacy.addEventListener("click", async () => {
    if (privateTransition) return;
    const enabled = !State.privateChat;
    privateTransition = true;
    State.memoryStatus = "Changing privacy…";
    State.notify();
    try {
      await Bridge.chatPrivate(enabled);
      State.privateChat = enabled;
      State.memoryStatus = enabled ? "Private chat — memory off" : null;
    } catch {
      State.memoryStatus = State.privateChat ? "Private chat — memory off" : "Privacy change failed";
    } finally {
      privateTransition = false;
      State.notify();
    }
  });
  const picker = modelPicker();
  // Spoken text is sent straight away: "press and tell it what to do".
  const mic = micControl(
    (text) => {
      const at = insertText(input.value, input.selectionStart ?? input.value.length, input.selectionEnd ?? input.value.length, text);
      input.value = at.value;
      void submit();
    },
    () => {
      onHeightChange();
      input.focus();
    },
  );
  const bar = h("div", { class: "chat-bar" }, privacy, picker.el, input, mic.button, send);

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, chipRow, log, mic.note, bar)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let privateTransition = false;
  let renderedKey = "";
  void onEvent<{ turnId: string; status: "saving" | "saved" | "notSaved" }>("chat-memory-status", ({ turnId, status }) => {
    const message = State.chatHistory.find((item) => item.turnId === turnId);
    if (message) message.memoryStatus = status;
    else State.pendingMemoryStatuses.set(turnId, status);
    State.memoryStatus = status === "saving" ? "Saving memory…" : status === "saved" ? "Memory saved" : "Memory not saved";
    State.notify();
  });

  async function submit() {
    const query = input.value.trim();
    if (!query || sending || privateTransition) return;
    input.value = "";
    sending = true;
    mic.clearNote();
    Sound.play("send");

    nextId = Math.max(nextId, nextChatId(State.chatHistory));
    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    State.notify();
    publishChat();
    onHeightChange();

    const file = State.droppedFile;
    const context: ChatContext | null =
      State.chatHistory.length === 1 && file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      const waiting = State.pendingApproval?.taskId ?? null;
      const reply = await Bridge.chatSend(query, context, sessionSnapshot(State.tasks, waiting));
      for (const action of reply.actions ?? []) {
        const line = actionLine(action);
        State.chatHistory.push({ id: nextId++, role: "action", content: line.text, actionKind: line.kind });
      }
      if (reply.text) {
        const turnId = reply.turnId ?? undefined;
        State.chatHistory.push(applyPendingMemoryStatus({ id: nextId++, role: "assistant", content: reply.text, turnId }, State.pendingMemoryStatuses));
      }
      State.memoryStatus = State.privateChat ? "Private chat — memory off" : reply.memoryStatus;
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      State.stateOverride = null;
      const message = String(err).replace(/^Error:\s*/, "");
      if (message !== CHAT_CLEARED) {
        if (options.inlineErrors) {
          State.chatHistory.push({ id: nextId++, role: "action", content: `✕ ${message}`, actionKind: "error" });
        } else {
          State.noteMessage = message;
          State.view = "note";
        }
        Sound.play("error");
      }
    } finally {
      sending = false;
      State.notify();
      publishChat();
      onHeightChange();
      input.focus();
    }
  }

  send.addEventListener("click", () => void submit());
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.isComposing) {
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
      const key = `${chatRenderKey(State.chatHistory)}:${thinking}`;
      if (key !== renderedKey) {
        renderedKey = key;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
      }

      input.placeholder = State.memoryStatus ?? (State.chatHistory.length === 0 ? "Ask me anything…" : "Continue…");
      privacy.setAttribute("aria-pressed", String(State.privateChat));
      privacy.textContent = State.privateChat ? "Private on" : "Private off";
      input.disabled = sending || privateTransition;
      send.toggleAttribute("disabled", sending || privateTransition);
      privacy.toggleAttribute("disabled", sending || privateTransition);
      mic.disabled = sending || privateTransition;
      picker.sync();
      picker.disabled = sending || privateTransition;
    },
    focus() {
      picker.refresh();
      input.focus();
      input.select();
    },
    toggleVoice() {
      if (!sending) mic.recorder.toggle();
    },
    cancelVoice() {
      mic.recorder.cancel();
    },
  };
}

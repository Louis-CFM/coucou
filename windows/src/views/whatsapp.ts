// The WhatsApp card — DOM port of WhatsAppCardView, WhatsAppRow,
// WhatsAppConversationView, WhatsAppBubble and WhatsAppAvatar
// (WhatsAppViews.swift). Sizes, colours and wording are the Mac's.
//
// The list shows one row per conversation with new messages; a click opens it
// with its last ten messages and a reply field. Enter sends, Shift+Enter starts
// a new line, Escape goes back to the list. Nothing is sent without the user's
// own Enter or click. What it shows comes from src-tauri/src/whatsapp through
// island/whatsapp.ts; no photo or media is ever fetched.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import {
  WHATSAPP_GREEN, WhatsApp, displayNumber, initials, linkColor, linkLabel, previewKey, previewLine, timeAgo,
  type WhatsAppConversation, type WhatsAppMessage,
} from "../core/whatsapp";
import { language, t } from "../i18n/i18n";

export interface WhatsAppCardHost {
  el: HTMLElement;
  sync(): void;
}

const GROUP_PATH = "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zm7.5 0a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM2 19.5C2 16.5 5 14 9 14s7 2.5 7 5.5V20H2v-.5zm15.2.5v-.5c0-1.9-.8-3.6-2.1-4.9.6-.1 1.2-.1 1.9-.1 3.2 0 5.5 2 5.5 4.6v.9h-5.3z";

/** Initials on WhatsApp green: no photo is ever fetched (they live on WhatsApp's servers). */
function avatar(name: string, isGroup: boolean, size = 16): HTMLElement {
  const el = h("span", { class: "wa-avatar", style: `width:${size}px;height:${size}px;font-size:${size * 0.42}px` });
  const letters = initials(name);
  if (isGroup && letters === "#") el.append(svg(GROUP_PATH, Math.round(size * 0.62)));
  else el.textContent = letters;
  return el;
}

function row(c: WhatsAppConversation, open: () => void): HTMLElement {
  const unread = c.unread > 0;
  const last = c.messages[c.messages.length - 1];
  const el = h("button", { class: unread ? "wa-row unread" : "wa-row", onclick: open },
    avatar(c.name, c.isGroup),
    h("span", { class: "wa-name", text: c.name }),
    h("span", { class: "wa-age", text: timeAgo(c.lastActivity) }),
    last ? h("span", { class: "wa-preview", text: previewLine(last, c.isGroup) }) : null,
    h("span", { class: "grow" }),
    unread ? h("span", { class: "wa-count", text: c.unread > 99 ? "99+" : String(c.unread) }) : null,
  );
  // The Mac's context menu: right-click ignores the chat.
  el.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    showIgnoreMenu(el, c.id, e.clientX, e.clientY);
  });
  return el;
}

let menu: HTMLElement | null = null;

function closeMenu() {
  menu?.remove();
  menu = null;
}

function showIgnoreMenu(anchor: HTMLElement, chat: string, x: number, y: number) {
  closeMenu();
  const item = h("button", {
    class: "wa-menu-item",
    text: t("Ignore this chat"),
    onclick: () => {
      closeMenu();
      void Bridge.whatsappIgnore(chat);
    },
  });
  menu = h("div", { class: "wa-menu", style: `left:${x}px;top:${y}px` }, item);
  document.body.append(menu);
  window.setTimeout(() => document.addEventListener("pointerdown", (e) => {
    if (menu && !menu.contains(e.target as Node)) closeMenu();
  }, { once: true }), 0);
  void anchor;
}

function bubble(m: WhatsAppMessage, isGroup: boolean): HTMLElement {
  const [key, value] = previewKey(m);
  const body = h("div", { class: "wa-bubble" });
  if (isGroup && !m.fromMe && m.senderName) body.append(h("div", { class: "wa-sender", text: m.senderName }));
  if (key) body.append(h("div", { class: "wa-media", text: t(key) }));
  if (value) body.append(h("div", { class: "wa-text", text: value }));
  return h("div", { class: m.fromMe ? "wa-line mine" : "wa-line" }, body);
}

/** `pin`: the island's own pin (Ctrl+P), so a draft keeps it open. */
export function buildWhatsAppCard(pin: (on: boolean) => void): WhatsAppCardHost {
  const el = h("div", { class: "wa-card" });

  // ── The list ──
  const listEl = h("div", { class: "int-card wa-list-card" });
  let listKey = "";

  // ── One conversation ──
  let openChat: string | null = null;
  const back = h("button", { class: "wa-back" }, svg(ICONS.chevronLeft, 10, { stroke: 2.4 }));
  const headAvatar = h("span");
  const headName = h("span", { class: "wa-head-name" });
  const head = h("div", { class: "wa-conv-head" }, back, headAvatar, headName);
  const messagesEl = h("div", { class: "wa-messages" });
  const draft = h("textarea", { class: "wa-draft", rows: "1", spellcheck: "true" }) as HTMLTextAreaElement;
  const send = h("button", { class: "wa-send" }, svg(ICONS.arrowUp, 10, { stroke: 2.6 }));
  const spinner = h("span", { class: "wa-spinner" });
  const reply = h("div", { class: "wa-reply" }, draft, send, spinner);
  const note = h("div", { class: "wa-note" });
  const convEl = h("div", { class: "wa-conv" }, head, messagesEl, reply, note);
  let convKey = "";
  let lastShown = "";

  /** `typing`: opened by a click, so the reply field takes the keyboard. A
   * conversation opened by a message coming in leaves it where it is. */
  function openConversation(id: string, typing = true) {
    openChat = id;
    draft.value = "";
    WhatsApp.drafting = false;
    convKey = "";
    lastShown = "";
    void Bridge.whatsappOpen(id);
    if (typing) {
      // The reply field needs the keyboard: the island lends it focus while open.
      void Bridge.focusWindow(true);
    }
    sync();
    if (typing) window.setTimeout(() => draft.focus(), 120);
  }

  function closeConversation() {
    if (openChat) void Bridge.whatsappClose(openChat);
    openChat = null;
    draft.value = "";
    setComposing(false);
    void Bridge.focusWindow(false);
    sync();
  }

  /** WhatsAppController.composing: a draft keeps the island open. Only a pin it set itself is lifted. */
  let pinnedByDraft = false;
  function setComposing(on: boolean) {
    WhatsApp.drafting = on;
    if (on && !State.isPinned) {
      pin(true);
      pinnedByDraft = true;
    } else if (!on && pinnedByDraft) {
      pinnedByDraft = false;
      if (!State.pendingApproval) pin(false);
    }
  }

  async function submit() {
    const text = draft.value;
    if (!openChat || !text.trim() || WhatsApp.state.sending) return;
    const ok = await Bridge.whatsappSend(openChat, text);
    if (ok) {
      draft.value = "";
      setComposing(false);
      paintSend();
    }
    draft.focus();
  }

  function paintSend() {
    const empty = !draft.value.trim();
    send.style.opacity = empty ? "0.3" : "1";
    (send as HTMLButtonElement).disabled = empty;
    draft.style.height = "auto";
    draft.style.height = `${Math.min(draft.scrollHeight, 44)}px`;
  }

  back.addEventListener("click", closeConversation);
  send.addEventListener("click", () => void submit());
  // Opened by a message: a click in the reply field asks for the keyboard.
  draft.addEventListener("mousedown", () => void Bridge.focusWindow(true));
  draft.addEventListener("input", () => {
    WhatsApp.drafting = draft.value.trim() !== "";
    setComposing(draft.value.trim() !== "");
    paintSend();
  });
  draft.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      void submit();
    } else if (e.key === "Escape") {
      // Back to the list, not the island folding away.
      e.preventDefault();
      e.stopPropagation();
      closeConversation();
    }
  });

  function syncList() {
    const s = WhatsApp.state;
    const connected = s.link.state === "connected";
    const key = [language(), s.link.state, JSON.stringify(s.link), s.unread,
      s.conversations.map((c) => `${c.id}:${c.unread}:${c.lastActivity}:${c.name}:${c.messages.at(-1)?.id ?? ""}`).join("|"),
      Math.floor(Date.now() / 60_000)].join("~");
    if (key === listKey) return;
    listKey = key;
    clear(listEl);
    const header = h("div", { class: "int-head" }, dot(WHATSAPP_GREEN, 7), h("b", { text: "WhatsApp" }));
    const unread = s.conversations.reduce((n, c) => n + c.unread, 0);
    if (unread > 0) header.append(h("span", { class: "wa-unread", text: t("{0} unread", { 0: unread }) }));
    listEl.append(header);
    if (connected) {
      if (s.conversations.length === 0) {
        listEl.append(h("div", { class: "wa-empty", text: t("No new messages") }));
      } else {
        listEl.append(h("div", { class: "wa-rows" }, ...s.conversations.map((c) => row(c, () => openConversation(c.id)))));
      }
    } else {
      listEl.append(
        h("div", { class: "int-status" }, dot(linkColor(s.link), 5), h("span", { class: "wa-status", text: linkLabel(s.link) })),
        h("div", { class: "int-actions" },
          h("button", { class: "link-btn", style: "color:#8E939C", text: t("Settings…"), onclick: () => void Bridge.openSettingsWindow() }),
        ),
      );
    }
  }

  function syncConversation(c: WhatsAppConversation) {
    const s = WhatsApp.state;
    const key = [language(), c.id, c.name, c.messages.map((m) => m.id).join("|")].join("~");
    if (key !== convKey) {
      convKey = key;
      clear(headAvatar);
      headAvatar.append(avatar(c.name, c.isGroup));
      headName.textContent = c.name;
      headName.title = displayNumber(c.id);
      clear(messagesEl);
      for (const m of c.messages) messagesEl.append(bubble(m, c.isGroup));
      draft.placeholder = t("Reply…  (Shift+Enter: new line)");
      const newest = c.messages.at(-1)?.id ?? "";
      if (newest !== lastShown) {
        lastShown = newest;
        requestAnimationFrame(() => messagesEl.scrollTo({ top: messagesEl.scrollHeight, behavior: "smooth" }));
      }
    }
    draft.disabled = s.sending;
    send.style.display = s.sending ? "none" : "";
    spinner.style.display = s.sending ? "" : "none";
    paintSend();
    if (s.link.state !== "connected") {
      note.textContent = linkLabel(s.link);
      note.style.color = "#F5B83D";
    } else if (s.sendError) {
      note.textContent = s.sendError;
      note.style.color = "#F4505E";
    } else {
      note.textContent = "";
    }
    note.style.display = note.textContent ? "" : "none";
  }

  function sync() {
    const s = WhatsApp.state;
    // A message just came in: its conversation, once it is in the list.
    const wanted = WhatsApp.openRequest;
    if (wanted && s.conversations.some((c) => c.id === wanted)) {
      WhatsApp.openRequest = null;
      if (openChat !== wanted) {
        openConversation(wanted, false);
        return;
      }
    }
    // Kept open through a missed check (the draft too): only gone when WhatsApp is off.
    const conversation = openChat && s.link.state !== "off" ? s.conversations.find((c) => c.id === openChat) : undefined;
    if (openChat && !conversation && s.link.state === "off") {
      openChat = null;
      setComposing(false);
    }
    if (conversation) {
      if (el.firstChild !== convEl) {
        clear(el);
        el.append(convEl);
      }
      syncConversation(conversation);
    } else {
      if (el.firstChild !== listEl) {
        clear(el);
        el.append(listEl);
        listKey = "";
      }
      syncList();
    }
  }

  // Leaving the card (another pill, the island folding) closes the conversation.
  State.subscribe(() => {
    if (!openChat) return;
    const shown = State.mode === "expanded" && State.view === "overview" && State.focusTask?.id === "integration_whatsapp";
    if (!shown) closeConversation();
  });

  return { el, sync };
}

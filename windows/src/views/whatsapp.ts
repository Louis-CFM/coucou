// The WhatsApp card — a DOM port of WhatsAppCardView, WhatsAppRow, WhatsAppConversationView,
// WhatsAppBubble and WhatsAppAvatar (WhatsAppViews.swift). Sizes, colours and wording are the Mac's.
//
// The list: one row per conversation (never one per message) with initials, name, age, the last
// message cut short and the unread count; when the gateway isn't linked, why, and a way to Settings.
// A click on a row opens the conversation: its last ten messages and a reply field. Enter sends,
// Shift+Enter starts a new line, Escape goes back to the list. Nothing is sent without the user's
// own Enter or click, and while a reply is being typed the island stays open.
//
// The magnifier finds someone, among the conversations and WhatsApp's address book, by name or
// number; a click or Enter opens their conversation here, empty when it is new, with the same
// reply field and the same rules (Rust only lets a new one start with someone in your contacts).
// If Rust refuses, WhatsApp opens at their chat instead. The address book is kept only while the
// search is open.
//
// Built once and synced in place: the field keeps its draft and the keyboard while messages arrive.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import {
  WHATSAPP_GREEN, WHATSAPP_ID, WhatsApp, canSend, findContacts, initials, keyAction, lastMessages, linkColor,
  linkLabel, preview, previewParts, sendErrorLabel, timeAgo, type WaContact, type WaConversation, type WaMessage,
} from "../core/whatsapp";
import { language, t, tl } from "../i18n/i18n";

export interface WhatsAppCardHost {
  openSettings(): void;
  /** The island takes the keyboard for the reply field, and gives it back. */
  keyboard(on: boolean): void;
  /** A reply is being typed: the island stays open until it is sent or cleared. */
  holdOpen(on: boolean): void;
}

export interface WhatsAppCard {
  el: HTMLElement;
  sync(): void;
}

/** Initials on WhatsApp green: no photo is ever fetched (they live on WhatsApp's servers). */
function avatar(name: string, isGroup: boolean, size = 16): HTMLElement {
  const letters = initials(name);
  const el = h("span", { class: "wa-avatar", style: `width:${size}px;height:${size}px;font-size:${size * 0.42}px` });
  if (isGroup && letters === "#") el.append(svg(ICONS.stack, size * 0.6, { fill: WHATSAPP_GREEN }));
  else el.textContent = letters;
  return el;
}

function bubble(m: WaMessage, isGroup: boolean): HTMLElement {
  const { label, value } = previewParts(m);
  const box = h("div", { class: m.fromMe ? "wa-bubble mine" : "wa-bubble" });
  if (isGroup && !m.fromMe && m.senderName) box.append(h("div", { class: "wa-sender", text: m.senderName }));
  if (label) box.append(h("div", { class: "wa-media", text: t(label) }));
  if (value) box.append(h("div", { class: "wa-text", text: value }));
  return h("div", { class: m.fromMe ? "wa-line mine" : "wa-line" }, box);
}

export function buildWhatsAppCard(host: WhatsAppCardHost): WhatsAppCard {
  // ── The list ──
  const unreadTag = h("span", { class: "wa-unread" });
  // The search, in the head: the magnifier, or the field and its ✕. Shown and hidden, never moved,
  // so the field keeps the keyboard while messages arrive.
  const searchBtn = h("button", { class: "wa-icon", title: tl("Search") }, svg(ICONS.magnifier, 10));
  const findField = h("input", { class: "wa-search", type: "text", spellcheck: "false" }) as HTMLInputElement;
  const closeSearch = h("button", { class: "wa-icon", title: tl("Close") }, svg(ICONS.xmark, 9));
  const headSpacer = h("span", { class: "wa-spacer" });
  const head = h("div", { class: "int-head wa-list-head" },
    dot(WHATSAPP_GREEN, 7), h("b", { text: "WhatsApp" }), unreadTag, findField, headSpacer, searchBtn, closeSearch);
  const listBody = h("div", {});
  const listView = h("div", { class: "wa-list" }, head, listBody);

  // ── The conversation ──
  const back = h("button", { class: "int-back wa-back", title: tl("Back") }, svg(ICONS.chevronLeft, 10, { stroke: 2.4 }));
  const convoAvatar = h("span", {});
  const convoName = h("b", { class: "wa-name" });
  const convoHead = h("div", { class: "wa-head" }, back, convoAvatar, convoName);
  const messages = h("div", { class: "wa-messages" });
  const field = h("textarea", { class: "wa-field", rows: "1", spellcheck: "true" }) as HTMLTextAreaElement;
  const sendBtn = h("button", { class: "wa-send", title: tl("Send") }, svg(ICONS.arrowUp, 12, { fill: "#0B0C0E" }));
  const reply = h("div", { class: "wa-reply" }, field, sendBtn);
  const note = h("div", { class: "wa-note" });
  const convoView = h("div", { class: "wa-convo" }, convoHead, messages, reply, note);

  const el = h("div", { class: "int-card wa-card" }, listView, convoView);

  let openChat: string | null = null;
  /** The row whose "Ignore this chat" is showing (a right-click on it). */
  let ignoring: string | null = null;
  let listKey = "";
  let convoKey = "";
  let searchOpen = false;
  /** The address book while the search is open, forgotten when it closes; null until it arrives. */
  let contacts: WaContact[] | null = null;
  /** The highlighted result: ↓ and ↑ move it, Enter opens it. */
  let picked = 0;
  let token = 0;

  const current = (): WaConversation | undefined =>
    openChat ? WhatsApp.view.conversations.find((c) => c.id === openChat) : undefined;

  const matches = (): WaContact[] => findContacts(findField.value, WhatsApp.view.conversations, contacts ?? []);

  function setSearch(on: boolean) {
    if (on === searchOpen) return;
    searchOpen = on;
    findField.value = "";
    picked = 0;
    contacts = null;
    const mine = ++token;
    if (on) {
      void Bridge.whatsappContacts().then((list) => {
        if (mine !== token) return;
        contacts = list ?? [];
        listKey = "";
        sync();
      });
      host.keyboard(true);
      window.setTimeout(() => findField.focus(), 80);
    } else {
      host.holdOpen(false);
      host.keyboard(false);
    }
    listKey = "";
    sync();
  }

  /** Someone picked: their conversation opens here, ready to type. Nothing is sent until Enter. */
  async function pick(p: WaContact | undefined) {
    if (!p) return;
    setSearch(false);
    if (!WhatsApp.view.conversations.some((c) => c.id === p.id)) {
      const view = await Bridge.whatsappStart(p.id);
      if (!view) {
        // Refused (not in your contacts, or the gateway didn't answer): WhatsApp itself, at the chat.
        void Bridge.whatsappOpenApp(p.id);
        return;
      }
      WhatsApp.view = view;
    }
    open(p.id);
  }

  searchBtn.addEventListener("click", () => setSearch(true));
  closeSearch.addEventListener("click", () => setSearch(false));
  findField.addEventListener("input", () => {
    picked = 0;
    // While a name is being typed the island stays open, as for a reply.
    host.holdOpen(findField.value.trim().length > 0);
    sync();
  });
  findField.addEventListener("keydown", (e) => {
    const key = (e as KeyboardEvent).key;
    const found = matches();
    if (key === "ArrowDown" || key === "ArrowUp") {
      e.preventDefault();
      if (found.length > 0) picked = (picked + (key === "ArrowDown" ? 1 : found.length - 1)) % found.length;
      sync();
    } else if (key === "Enter" && !(e as KeyboardEvent).isComposing) {
      e.preventDefault();
      void pick(found[Math.min(picked, found.length - 1)]);
    } else if (key === "Escape") {
      // Back to the list, not the island folding away.
      e.preventDefault();
      setSearch(false);
    }
    e.stopPropagation();
  });

  function open(id: string) {
    if (searchOpen) setSearch(false);
    openChat = id;
    ignoring = null;
    field.value = "";
    convoKey = "";
    void Bridge.whatsappOpen(id);
    host.keyboard(true);
    window.setTimeout(() => field.focus(), 120);
    sync();
  }

  function close() {
    if (openChat == null) return;
    void Bridge.whatsappClose(openChat);
    openChat = null;
    field.value = "";
    host.holdOpen(false);
    host.keyboard(false);
    listKey = "";
    sync();
  }

  async function send() {
    const chat = openChat;
    const text = field.value;
    if (!chat || !canSend(text, WhatsApp.view.sending)) return;
    const sent = await Bridge.whatsappSend(chat, text);
    if (sent && openChat === chat && field.value === text) {
      field.value = "";
      host.holdOpen(false);
      syncSendButton();
    }
    field.focus();
  }

  back.addEventListener("click", close);
  sendBtn.addEventListener("click", () => void send());
  field.addEventListener("input", () => {
    host.holdOpen(field.value.trim().length > 0);
    syncSendButton();
  });
  field.addEventListener("keydown", (e) => {
    const action = keyAction(e);
    if (action === "send") {
      e.preventDefault();
      void send();
    } else if (action === "back") {
      // Back to the list, not the island folding away.
      e.preventDefault();
      e.stopPropagation();
      close();
    }
  });

  // Leaving the card (another pill, another view, the island folded) closes the conversation, and
  // the search with its copy of the address book.
  State.subscribe(() => {
    if (openChat == null && !searchOpen) return;
    if (State.mode !== "expanded" || State.view !== "overview" || State.focusTask?.id !== WHATSAPP_ID || !WhatsApp.view.on) {
      close();
      setSearch(false);
    }
  });

  function syncSendButton() {
    const ok = canSend(field.value, WhatsApp.view.sending);
    sendBtn.classList.toggle("ready", ok);
    sendBtn.disabled = !ok;
    field.disabled = WhatsApp.view.sending;
  }

  function row(c: WaConversation): HTMLElement {
    const unread = c.unread > 0;
    const r = h("button", { class: unread ? "int-row wa-row unread" : "int-row wa-row" },
      avatar(c.name, c.isGroup),
      h("span", { class: "int-name wa-row-name", text: c.name }),
      h("span", { class: "int-ago", text: timeAgo(c.lastActivity) }),
    );
    const last = c.messages[c.messages.length - 1];
    if (ignoring === c.id) {
      r.append(h("span", { class: "wa-spacer" }), h("span", {
        class: "link-btn wa-ignore",
        text: t("Ignore this chat"),
        onclick: (e: Event) => {
          e.stopPropagation();
          ignoring = null;
          void Bridge.whatsappIgnore(c.id);
        },
      }));
    } else {
      if (last) r.append(h("span", { class: "int-sub wa-preview", text: preview(last, c.isGroup) }));
      r.append(h("span", { class: "wa-spacer" }));
      if (unread) r.append(h("span", { class: "wa-count", text: c.unread > 99 ? "99+" : String(c.unread) }));
    }
    r.addEventListener("click", () => open(c.id));
    r.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      ignoring = ignoring === c.id ? null : c.id;
      listKey = "";
      sync();
    });
    return r;
  }

  /** A search result: the name and number; a click opens their chat in WhatsApp. */
  function contactRow(p: WaContact, i: number): HTMLElement {
    const r = h("button", { class: i === picked ? "int-row wa-row selected" : "int-row wa-row" },
      avatar(p.name, false),
      h("span", { class: "int-name wa-row-name", text: p.name }),
      h("span", { class: "int-sub wa-preview", text: `+${p.id.split("@")[0]}` }),
    );
    r.addEventListener("click", () => void pick(p));
    return r;
  }

  function syncList() {
    const v = WhatsApp.view;
    const query = searchOpen ? findField.value.trim() : "";
    const key = [
      language(), v.link.state, "detail" in v.link ? v.link.detail : "", v.unread, ignoring,
      searchOpen, query, picked, contacts?.length ?? -1,
      // The ages move on a minute at a time.
      Math.floor(Date.now() / 60_000),
      ...v.conversations.map((c) => `${c.id}|${c.name}|${c.unread}|${c.lastActivity}|${c.messages[c.messages.length - 1]?.id ?? ""}`),
    ].join("~");
    if (key === listKey) return;
    listKey = key;
    unreadTag.textContent = v.unread > 0 ? t("{0} unread", { 0: v.unread }) : "";
    unreadTag.style.display = v.unread > 0 && !searchOpen ? "" : "none";
    findField.placeholder = t("Find a contact");
    findField.style.display = searchOpen ? "" : "none";
    closeSearch.style.display = searchOpen ? "" : "none";
    headSpacer.style.display = searchOpen ? "none" : "";
    searchBtn.style.display = !searchOpen && v.link.state === "connected" ? "" : "none";
    clear(listBody);
    if (v.link.state !== "connected") {
      listBody.append(
        h("div", { class: "int-status" }, dot(linkColor(v.link), 5), h("span", { class: "wa-status-text", text: linkLabel(v.link) })),
        h("div", { class: "int-actions" }, h("button", {
          class: "link-btn wa-settings", text: t("Settings…"), onclick: () => host.openSettings(),
        })),
      );
    } else if (query) {
      const found = matches();
      if (found.length > 0) listBody.append(h("div", { class: "int-rows wa-rows" }, ...found.map(contactRow)));
      else listBody.append(h("div", { class: "wa-empty", text: contacts == null ? t("Loading…") : t("Nobody by that name") }));
    } else if (v.conversations.length === 0) {
      listBody.append(h("div", { class: "wa-empty", text: t("No new messages") }));
    } else {
      listBody.append(h("div", { class: "int-rows wa-rows" }, ...v.conversations.map(row)));
    }
  }

  function syncConversation(c: WaConversation) {
    const v = WhatsApp.view;
    const shown = lastMessages(c);
    const key = [language(), c.id, c.name, ...shown.map((m) => m.id)].join("~");
    if (key !== convoKey) {
      const wasAtBottom = messages.scrollHeight - messages.scrollTop - messages.clientHeight < 24;
      const first = convoKey === "";
      convoKey = key;
      clear(convoAvatar);
      convoAvatar.append(avatar(c.name, c.isGroup));
      convoName.textContent = c.name;
      convoName.title = c.id.split("@")[0];
      clear(messages);
      for (const m of shown) messages.append(bubble(m, c.isGroup));
      // The newest at the bottom, in view.
      if (first || wasAtBottom) messages.scrollTop = messages.scrollHeight;
    }
    field.placeholder = t("Reply…  (Shift+Enter: new line)");
    note.className = "wa-note";
    if (v.link.state !== "connected") {
      note.textContent = linkLabel(v.link);
      note.classList.add("warn");
    } else if (v.sendError) {
      note.textContent = sendErrorLabel(v.sendError);
      note.classList.add("err");
    } else {
      note.textContent = "";
    }
    syncSendButton();
  }

  function sync() {
    const c = current();
    // Kept open through a missed check (the draft too): only gone when WhatsApp is off or the
    // conversation left the list (ignored).
    if (openChat != null && (!c || !WhatsApp.view.on)) {
      close();
      return;
    }
    listView.style.display = c ? "none" : "";
    convoView.style.display = c ? "" : "none";
    if (c) syncConversation(c);
    else syncList();
  }

  return { el, sync };
}

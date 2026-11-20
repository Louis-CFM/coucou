// The WhatsApp card — a DOM port of WhatsAppCardView, WhatsAppRow, WhatsAppConversationView,
// WhatsAppBubble and WhatsAppAvatar (WhatsAppViews.swift). Sizes, colours and wording are the Mac's.
//
// The list: one row per conversation (never one per message) with initials, name, age, the last
// message cut short and the unread count; when the gateway isn't linked, why, and a way to Settings.
// A click on a row opens the conversation: its last ten messages and a reply field. Enter sends,
// Shift+Enter starts a new line, Escape goes back to the list. Nothing is sent without the user's
// own Enter or click, and while a reply is being typed the island stays open.
//
// Built once and synced in place: the field keeps its draft and the keyboard while messages arrive.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import {
  WHATSAPP_ID, WhatsApp, canSend, initials, keyAction, lastMessages, linkColor, linkLabel,
  preview, previewParts, sendErrorLabel, timeAgo, type WaConversation, type WaMessage,
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

/** Circular contact avatar with centered initials or genuine profile photo. */
function avatar(name: string, isGroup: boolean, size = 24, avatarUrl?: string): HTMLElement {
  const el = h("span", {
    class: "wa-avatar",
    style: `--wa-avatar-size:${size}px;width:${size}px;height:${size}px;font-size:${Math.round(size * 0.42)}px`,
  });

  const renderInitials = () => {
    const letters = initials(name);
    if (isGroup && letters === "#") {
      el.append(svg(ICONS.stack, Math.round(size * 0.55), { stroke: 1.6, fill: "none" }));
    } else {
      el.textContent = letters;
    }
  };

  if (avatarUrl) {
    const img = h("img", {
      class: "wa-avatar-img",
      src: avatarUrl,
      alt: name,
    }) as HTMLImageElement;
    img.onerror = () => {
      img.remove();
      renderInitials();
    };
    el.append(img);
  } else {
    renderInitials();
  }

  return el;
}

function bubble(m: WaMessage, isGroup: boolean): HTMLElement {
  const { label, value } = previewParts(m);
  const box = h("div", { class: m.fromMe ? "wa-bubble mine" : "wa-bubble" });
  if (isGroup && !m.fromMe && m.senderName) box.append(h("div", { class: "wa-sender", text: m.senderName }));
  if (label) box.append(h("span", { class: "wa-media", text: t(label) }));
  if (value) box.append(h("span", { class: "wa-text", text: value }));
  return h("div", { class: m.fromMe ? "wa-line mine" : "wa-line" }, box);
}

export function buildWhatsAppCard(host: WhatsAppCardHost): WhatsAppCard {
  // ── The list ──
  const unreadTag = h("span", { class: "wa-unread" });
  const head = h("div", { class: "int-head wa-head-fixed" }, h("b", { class: "wa-title", text: "WhatsApp" }), unreadTag);
  const listBody = h("div", { class: "wa-list-body" });
  const listView = h("div", { class: "wa-list" }, head, listBody);

  // ── The conversation ──
  const back = h("button", { class: "int-back wa-back", title: tl("Back") }, svg(ICONS.chevronLeft, 11, { stroke: 2.4 }));
  const convoAvatar = h("span", { class: "wa-head-avatar" });
  const convoName = h("b", { class: "wa-name" });
  const convoHead = h("div", { class: "wa-head" }, back, convoAvatar, convoName);
  const messages = h("div", { class: "wa-messages" });
  const field = h("textarea", { class: "wa-field", rows: "1", spellcheck: "true" }) as HTMLTextAreaElement;
  const sendBtn = h("button", { class: "wa-send", title: tl("Send") }, svg(ICONS.arrowUp, 12));
  const reply = h("div", { class: "wa-reply" }, field, sendBtn);
  const note = h("div", { class: "wa-note" });
  const convoView = h("div", { class: "wa-convo" }, convoHead, messages, reply, note);

  const el = h("div", { class: "int-card wa-card" }, listView, convoView);

  let openChat: string | null = null;
  /** The row whose "Ignore this chat" is showing (a right-click on it). */
  let ignoring: string | null = null;
  let listKey = "";
  let convoKey = "";
  let savedScrollTop = 0;
  let rowsEl: HTMLElement | null = null;

  const current = (): WaConversation | undefined =>
    openChat ? WhatsApp.view.conversations.find((c) => c.id === openChat) : undefined;

  function open(id: string) {
    if (rowsEl) savedScrollTop = rowsEl.scrollTop;
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
    if (rowsEl) {
      const top = savedScrollTop;
      requestAnimationFrame(() => {
        if (rowsEl) rowsEl.scrollTop = top;
      });
    }
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

  // Leaving the card (another pill, another view, the island folded) closes the conversation.
  State.subscribe(() => {
    if (openChat == null) return;
    if (State.mode !== "expanded" || State.view !== "overview" || State.focusTask?.id !== WHATSAPP_ID || !WhatsApp.view.on) {
      close();
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
    const last = c.messages[c.messages.length - 1];

    const av = avatar(c.name, c.isGroup, 24);

    const nameEl = h("span", { class: "int-name wa-row-name", text: c.name });
    const previewEl = last ? h("span", { class: "int-sub wa-preview", text: preview(last, c.isGroup) }) : null;
    const centerEl = h("div", { class: "wa-row-center" }, nameEl);
    if (previewEl) centerEl.append(previewEl);

    const timeEl = h("span", { class: "int-ago wa-row-time", text: timeAgo(c.lastActivity) });
    const rightEl = h("div", { class: "wa-row-right" }, timeEl);

    if (ignoring === c.id) {
      rightEl.append(h("span", {
        class: "link-btn wa-ignore",
        text: t("Ignore this chat"),
        onclick: (e: Event) => {
          e.stopPropagation();
          ignoring = null;
          void Bridge.whatsappIgnore(c.id);
        },
      }));
    } else if (unread) {
      rightEl.append(h("span", { class: "wa-count", text: c.unread > 99 ? "99+" : String(c.unread) }));
    }

    const r = h("button", { class: unread ? "int-row wa-row unread" : "int-row wa-row" },
      av,
      centerEl,
      rightEl,
    );
    r.addEventListener("click", () => open(c.id));
    r.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      ignoring = ignoring === c.id ? null : c.id;
      listKey = "";
      sync();
    });
    return r;
  }

  function syncList() {
    const v = WhatsApp.view;
    const key = [
      language(), v.link.state, "detail" in v.link ? v.link.detail : "", v.unread, ignoring,
      // The ages move on a minute at a time.
      Math.floor(Date.now() / 60_000),
      ...v.conversations.map((c) => `${c.id}|${c.name}|${c.unread}|${c.lastActivity}|${c.messages[c.messages.length - 1]?.id ?? ""}`),
    ].join("~");
    if (key === listKey) return;
    listKey = key;
    unreadTag.textContent = v.unread > 0 ? t("{0} unread", { 0: v.unread }) : "";
    unreadTag.style.display = v.unread > 0 ? "" : "none";
    const currentScroll = rowsEl ? rowsEl.scrollTop : savedScrollTop;
    clear(listBody);
    if (v.link.state !== "connected") {
      rowsEl = null;
      listBody.append(
        h("div", { class: "int-status" }, dot(linkColor(v.link), 5), h("span", { class: "wa-status-text", text: linkLabel(v.link) })),
        h("div", { class: "int-actions" }, h("button", {
          class: "link-btn wa-settings", text: t("Settings…"), onclick: () => host.openSettings(),
        })),
      );
    } else if (v.conversations.length === 0) {
      rowsEl = null;
      listBody.append(h("div", { class: "wa-empty", text: t("No new messages") }));
    } else {
      const rows = h("div", { class: "int-rows wa-rows" }, ...v.conversations.map(row));
      rowsEl = rows;
      listBody.append(rows);
      if (currentScroll > 0) {
        rows.scrollTop = currentScroll;
      }
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
      convoAvatar.append(avatar(c.name, c.isGroup, 24));
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

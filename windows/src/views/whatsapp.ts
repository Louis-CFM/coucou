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
  MAX_MEDIA_BYTES, MEDIA_LABELS, WHATSAPP_GREEN, WHATSAPP_ID, WhatsApp, canSend, chatList, initials, keyAction, lastMessages,
  linkColor, linkLabel, mergeMessages, preview, previewParts, sendErrorLabel, timeAgo, type WaChatSummary,
  type WaConversation, type WaMessage, type WaSendError,
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
  const head = h("div", { class: "int-head" }, dot(WHATSAPP_GREEN, 7), h("b", { text: "WhatsApp" }), unreadTag);
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

  const current = (): WaConversation | undefined =>
    openChat ? WhatsApp.view.conversations.find((c) => c.id === openChat) : undefined;

  function open(id: string) {
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
    clear(listBody);
    if (v.link.state !== "connected") {
      listBody.append(
        h("div", { class: "int-status" }, dot(linkColor(v.link), 5), h("span", { class: "wa-status-text", text: linkLabel(v.link) })),
        h("div", { class: "int-actions" }, h("button", {
          class: "link-btn wa-settings", text: t("Settings…"), onclick: () => host.openSettings(),
        })),
      );
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

// ── The big WhatsApp chat ─────────────────────────────────────────────────────
//
// The chat view on WhatsApp's Mochi is WhatsApp, in a taller island (layout.ts
// WHATSAPP_CHAT_H). The chats on one side (the inbox's, then the gateway's latest; the ones
// archived on the phone under "Archived"), the one picked on the other with its whole history,
// older pages fetched as it scrolls up, its photos and videos, and the card's reply field and
// rules. A chat only opens on a click (opening one may send its read receipt), and nothing leaves
// without the user's own Enter or click: a reply, a photo or video (picked or dropped, the field
// as its caption), a forward (the chat picked, then "Forward to …"). The history and the media
// (blob: URLs) live in this page while their chat is open, nowhere else; Escape steps back.

/** The chat view is WhatsApp on WhatsApp's Mochi; a dropped file is for the AI chat. */
export function showsWhatsAppChat(): boolean {
  return State.focusTask?.id === WHATSAPP_ID && !State.droppedFile;
}

/** Where a file dropped on the island goes while a chat is open in the big WhatsApp chat (to send
 *  with the next reply, instead of the drop sequence); null otherwise. */
let dropTarget: ((path: string) => void) | null = null;

export function whatsAppDropTarget(): ((path: string) => void) | null {
  return dropTarget;
}

export interface WhatsAppChatHost {
  openSettings(): void;
  /** A reply is being typed: the island stays open until it is sent or cleared. */
  holdOpen(on: boolean): void;
  /** Escape: back to the overview and its WhatsApp card. */
  back(): void;
}

export interface WhatsAppChat {
  el: HTMLElement;
  sync(): void;
  focus(): void;
}

/** A photo or video waiting to go with the next reply: dropped (its path) or picked (the file). */
interface Attachment {
  name: string;
  path?: string;
  file?: File;
}

export function buildWhatsAppChat(host: WhatsAppChatHost): WhatsAppChat {
  const unreadTag = h("span", { class: "wa-unread" });
  const listBack = h("button", { class: "int-back wa-back", title: tl("Back") }, svg(ICONS.chevronLeft, 10, { stroke: 2.4 }));
  const headDot = dot(WHATSAPP_GREEN, 7);
  const listTitle = h("b", { text: "WhatsApp" });
  const head = h("div", { class: "int-head" }, listBack, headDot, listTitle, unreadTag);
  const listBody = h("div", { class: "wa-chat-rows" });
  const list = h("div", { class: "wa-list wa-chat-list" }, head, listBody);

  const convoAvatar = h("span", {});
  const convoName = h("b", { class: "wa-name" });
  const messages = h("div", { class: "wa-messages" });
  const field = h("textarea", { class: "wa-field", rows: "1", spellcheck: "true" }) as HTMLTextAreaElement;
  const sendBtn = h("button", { class: "wa-send", title: tl("Send") }, svg(ICONS.arrowUp, 12, { fill: "#0B0C0E" }));
  const picker = h("input", { type: "file", accept: "image/*,video/*", class: "wa-file" }) as HTMLInputElement;
  const attachBtn = h("button", { class: "wa-attach", title: tl("Photo or video") }, svg(ICONS.plus, 12));
  const reply = h("div", { class: "wa-reply" }, attachBtn, field, sendBtn, picker);
  const attachedName = h("span", { class: "wa-attached-name" });
  const attached = h("div", { class: "wa-attached" }, attachedName,
    h("button", { class: "wa-attached-x", title: tl("Remove"), onclick: () => setAttachment(null) }, svg(ICONS.xmark, 8)));
  const fwdText = h("span", { class: "wa-forward-text" });
  const fwdSend = h("button", { class: "wa-forward-send" });
  const fwdCancel = h("button", { class: "link-btn wa-forward-cancel", text: tl("Cancel") });
  const forwardBar = h("div", { class: "wa-reply wa-forward" }, fwdText, fwdSend, fwdCancel);
  const note = h("div", { class: "wa-note" });
  const convo = h("div", { class: "wa-convo" },
    h("div", { class: "wa-head" }, convoAvatar, convoName), messages, attached, reply, forwardBar, note);
  const pick = h("div", { class: "wa-empty", text: tl("Choose a conversation") });
  // A photo at full size, over the panel; a click or Escape closes it.
  const viewerImg = h("img", { class: "wa-viewer-img", alt: "" }) as HTMLImageElement;
  const viewer = h("div", { class: "wa-viewer" }, viewerImg,
    h("button", { class: "wa-viewer-x", title: tl("Close") }, svg(ICONS.xmark, 10)));

  const el = h("div", { class: "card wash chat-card wa-chat" },
    h("div", { class: "wa-chat-body" }, list, h("div", { class: "wa-chat-side" }, pick, convo)), viewer);
  el.style.setProperty("--wash", "rgba(37,211,102,0.3)");

  let shown = false;
  let gatewayChats: WaChatSummary[] = [];
  let showArchived = false;
  let openChat: string | null = null;
  /** The pages fetched for the open chat; the inbox's own messages are merged in at each sync. */
  let older: WaMessage[] = [];
  let fetched = false;
  let loading = false;
  let complete = false;
  let attachment: Attachment | null = null;
  /** A refusal found here, before anything went to Rust (a file too big to read). */
  let localError: WaSendError | null = null;
  /** The message being forwarded, and the chat picked for it. */
  let forwarding: WaMessage | null = null;
  let forwardTo: string | null = null;
  /** "Forwarded to …", until the next step. */
  let flash = "";
  /** The open chat's photos and videos, by message id: blob: URLs, revoked when it closes. */
  const media = new Map<string, Promise<string | null>>();
  /** The open chat's bubbles, by message id: kept as messages arrive, so a playing video plays on. */
  const nodes = new Map<string, HTMLElement>();
  let nodesLanguage = "";
  let listKey = "";
  let convoKey = "";

  const allChats = () => chatList(WhatsApp.view.conversations, gatewayChats);
  const current = () => (openChat ? allChats().find((c) => c.id === openChat) : undefined);
  const shownMessages = (c: WaConversation) => mergeMessages(older, c.messages);
  const ready = () => !WhatsApp.view.sending && (field.value.trim().length > 0 || attachment != null);

  // Photos load as they scroll into view, not all at once.
  const loaders = new WeakMap<Element, () => void>();
  const watcher = typeof IntersectionObserver === "undefined" ? null : new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      watcher?.unobserve(e.target);
      loaders.get(e.target)?.();
    }
  }, { root: messages, rootMargin: "200px" });

  async function refreshChats() {
    const got = await Bridge.whatsappChats();
    if (!got) return;
    gatewayChats = got;
    if (shown) sync();
  }

  function open(id: string) {
    if (openChat === id) return;
    close();
    openChat = id;
    field.value = "";
    flash = "";
    dropTarget = (path) => setAttachment({ name: path.split(/[\\/]/).pop() || path, path });
    void Bridge.whatsappOpen(id);
    sync();
    void loadOlder();
    window.setTimeout(() => field.focus(), 0);
  }

  function close() {
    if (openChat == null) return;
    void Bridge.whatsappClose(openChat);
    openChat = null;
    dropTarget = null;
    older = [];
    fetched = loading = complete = false;
    field.value = "";
    attachment = null;
    localError = null;
    forwarding = null;
    forwardTo = null;
    flash = "";
    closeViewer();
    for (const got of media.values()) void got.then((url) => url && URL.revokeObjectURL(url));
    media.clear();
    nodes.clear();
    clear(messages);
    host.holdOpen(false);
    listKey = convoKey = "";
  }

  /** The latest page first, then the page before the oldest message shown, one at a time. */
  async function loadOlder() {
    const chat = openChat;
    const c = current();
    if (!chat || !c || loading || complete) return;
    loading = true;
    const first = !fetched;
    const page = await Bridge.whatsappHistory(chat, first ? null : shownMessages(c)[0]?.date ?? null);
    if (chat !== openChat) return;
    loading = false;
    // The gateway didn't answer: tried again on the next scroll up.
    if (!page) return;
    fetched = true;
    const had = new Set(shownMessages(current() ?? c).map((m) => m.id));
    if (page.every((m) => had.has(m.id))) complete = true;
    older = mergeMessages(older, page);
    // Older messages come in above: what is on screen stays where it was.
    const fromBottom = messages.scrollHeight - messages.scrollTop;
    sync();
    if (!first) messages.scrollTop = messages.scrollHeight - fromBottom;
  }

  function setAttachment(a: Attachment | null) {
    attachment = a;
    localError = null;
    flash = "";
    host.holdOpen(a != null || field.value.trim().length > 0);
    sync();
    if (a) field.focus();
  }

  async function send() {
    const chat = openChat;
    const text = field.value;
    const file = attachment;
    if (!chat || !ready()) return;
    localError = null;
    flash = "";
    const sent = !file
      ? await Bridge.whatsappSend(chat, text)
      : file.path
        ? await Bridge.whatsappSendFile(chat, file.path, text)
        : file.file
          ? await Bridge.whatsappSendBytes(chat, file.file, text)
          : false;
    if (sent && openChat === chat && field.value === text) {
      field.value = "";
      if (attachment === file) attachment = null;
      host.holdOpen(false);
    }
    sync();
    field.focus();
  }

  // ── Forwarding: the message, then a chat on the list, then the click that sends it ──

  function startForward(m: WaMessage) {
    forwarding = m;
    forwardTo = null;
    flash = "";
    listKey = "";
    sync();
  }

  function cancelForward() {
    forwarding = null;
    forwardTo = null;
    listKey = "";
    sync();
  }

  async function sendForward() {
    const m = forwarding;
    const to = forwardTo ? allChats().find((c) => c.id === forwardTo) : undefined;
    if (!m || !to || WhatsApp.view.sending) return;
    const ok = await Bridge.whatsappForward(m.chat, m.id, to.id);
    if (forwarding !== m) return;
    if (ok) {
      forwarding = null;
      forwardTo = null;
      flash = t("Forwarded to {name}", { name: to.name });
      listKey = "";
    }
    sync();
  }

  // ── Photos and videos ──

  /** A message's photo or video, fetched once through the gateway while its chat is open. */
  function mediaUrl(m: WaMessage): Promise<string | null> {
    let got = media.get(m.id);
    if (!got) {
      const asked = Bridge.whatsappMedia(m.chat, m.id, m.media.kind === "video" ? "video/mp4" : "");
      media.set(m.id, asked);
      // Not there: asked again on the next click.
      void asked.then((url) => {
        if (!url && media.get(m.id) === asked) media.delete(m.id);
      });
      got = asked;
    }
    return got;
  }

  function openViewer(url: string) {
    viewerImg.src = url;
    viewer.classList.add("on");
  }

  function closeViewer() {
    viewer.classList.remove("on");
    viewerImg.removeAttribute("src");
  }

  /** The bubble's photo (shown as it scrolls into view, a click for full size) or video (a click
   *  plays it there, with its controls: it can be large). Until then, its label. */
  function mediaView(m: WaMessage): HTMLElement {
    const video = m.media.kind === "video";
    const label = t(video ? MEDIA_LABELS.video : MEDIA_LABELS.image);
    const box = h("button", { class: video ? "wa-thumb video" : "wa-thumb", title: label },
      svg(video ? ICONS.play : ICONS.eye, 14), h("span", { text: label }));
    let url: string | null = null;
    const show = (u: string) => {
      url = u;
      if (!video) box.replaceChildren(h("img", { class: "wa-thumb-img", src: u, alt: label }));
    };
    box.addEventListener("click", async () => {
      const u = url ?? (await mediaUrl(m));
      if (!u) return;
      if (!video) {
        show(u);
        openViewer(u);
        return;
      }
      const player = h("video", { class: "wa-video", src: u, controls: "", autoplay: "" });
      box.replaceWith(player);
    });
    if (!video) {
      const load = () => void mediaUrl(m).then((u) => u && show(u));
      if (watcher) {
        loaders.set(box, load);
        watcher.observe(box);
      } else {
        load();
      }
    }
    return box;
  }

  function chatBubble(m: WaMessage, isGroup: boolean): HTMLElement {
    const { label, value } = previewParts(m);
    const box = h("div", { class: m.fromMe ? "wa-bubble mine" : "wa-bubble" });
    if (isGroup && !m.fromMe && m.senderName) box.append(h("div", { class: "wa-sender", text: m.senderName }));
    if (m.forwarded) box.append(h("div", { class: "wa-forwarded", text: t("Forwarded") }));
    if (m.media.kind === "image" || m.media.kind === "video") box.append(mediaView(m));
    else if (label) box.append(h("div", { class: "wa-media", text: t(label) }));
    if (value) box.append(h("div", { class: "wa-text", text: value }));
    const line = h("div", { class: m.fromMe ? "wa-line mine" : "wa-line" });
    // "Forward" on hover or a right-click; not for a message Coucou just sent (no id the gateway knows).
    if (m.id.startsWith("coucou-")) {
      line.append(box);
      return line;
    }
    const fwd = h("button", { class: "link-btn wa-fwd", text: t("Forward"), onclick: () => startForward(m) });
    if (m.fromMe) line.append(fwd, box);
    else line.append(box, fwd);
    line.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      line.classList.toggle("offer");
    });
    return line;
  }

  messages.addEventListener("scroll", () => {
    if (messages.scrollTop < 40) void loadOlder();
  });
  sendBtn.addEventListener("click", () => void send());
  attachBtn.addEventListener("click", () => picker.click());
  picker.addEventListener("change", () => {
    const file = picker.files?.[0];
    picker.value = "";
    if (!file) return;
    if (file.size > MAX_MEDIA_BYTES) {
      localError = { code: "tooBig" };
      sync();
      return;
    }
    setAttachment({ name: file.name, file });
  });
  fwdSend.addEventListener("click", () => void sendForward());
  fwdCancel.addEventListener("click", cancelForward);
  viewer.addEventListener("click", closeViewer);
  listBack.addEventListener("click", () => {
    showArchived = false;
    listKey = "";
    sync();
  });
  field.addEventListener("input", () => {
    flash = "";
    host.holdOpen(field.value.trim().length > 0 || attachment != null);
    syncSendButton();
  });
  field.addEventListener("keydown", (e) => {
    if (keyAction(e) === "send") {
      e.preventDefault();
      void send();
    }
  });
  // Escape, one step back at a time: the photo at full size, the forward, then out to the card,
  // never the island folding away.
  el.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    e.preventDefault();
    e.stopPropagation();
    if (viewer.classList.contains("on")) closeViewer();
    else if (forwarding) cancelForward();
    else host.back();
  });

  // Leaving it (another view or Mochi, the island folded) closes the chat; the next time it
  // shows, the gateway's list is asked again.
  State.subscribe(() => {
    if (State.mode === "expanded" && State.view === "prompt" && showsWhatsAppChat()) return;
    shown = false;
    showArchived = false;
    close();
  });

  function syncSendButton() {
    const ok = ready();
    sendBtn.classList.toggle("ready", ok);
    sendBtn.disabled = !ok;
    field.disabled = WhatsApp.view.sending;
  }

  function row(c: WaConversation): HTMLElement {
    const last = c.messages[c.messages.length - 1];
    const on = c.id === (forwarding ? forwardTo : openChat);
    const r = h("button", { class: `int-row wa-row wa-chat-row${c.unread > 0 ? " unread" : ""}${on ? " on" : ""}` },
      avatar(c.name, c.isGroup, 26),
      h("span", { class: "wa-chat-text" },
        h("span", { class: "wa-chat-line" },
          h("span", { class: "int-name wa-row-name", text: c.name }),
          h("span", { class: "wa-spacer" }),
          h("span", { class: "int-ago", text: timeAgo(c.lastActivity) })),
        h("span", { class: "wa-chat-line" },
          h("span", { class: "int-sub wa-preview", text: last ? preview(last, c.isGroup) : "" }),
          h("span", { class: "wa-spacer" }),
          c.unread > 0 ? h("span", { class: "wa-count", text: c.unread > 99 ? "99+" : String(c.unread) }) : null)),
    );
    r.addEventListener("click", () => {
      // While forwarding, a click picks where it goes; nothing is sent yet.
      if (!forwarding) return open(c.id);
      forwardTo = c.id;
      listKey = "";
      sync();
    });
    return r;
  }

  /** WhatsApp's "Archived" at the top of the list: the chats archived on the phone, behind a click. */
  function archivedRow(count: number): HTMLElement {
    return h("button", {
      class: "int-row wa-row wa-chat-row wa-archived",
      onclick: () => {
        showArchived = true;
        listKey = "";
        sync();
      },
    },
    h("span", { class: "wa-archived-icon" }, svg(ICONS.stack, 13)),
    h("span", { class: "int-name wa-row-name", text: t("Archived") }),
    h("span", { class: "wa-spacer" }),
    h("span", { class: "int-ago", text: String(count) }));
  }

  function syncList(shownChats: WaConversation[], archivedCount: number) {
    const v = WhatsApp.view;
    const key = [
      language(), v.link.state, "detail" in v.link ? v.link.detail : "", v.unread, openChat, showArchived, archivedCount,
      forwarding?.id, forwardTo,
      // The ages move on a minute at a time.
      Math.floor(Date.now() / 60_000),
      ...shownChats.map((c) => `${c.id}|${c.name}|${c.unread}|${c.lastActivity}|${c.messages[c.messages.length - 1]?.id ?? ""}`),
    ].join("~");
    if (key === listKey) return;
    listKey = key;
    listBack.style.display = showArchived ? "" : "none";
    headDot.style.display = showArchived ? "none" : "";
    listTitle.textContent = showArchived ? t("Archived") : "WhatsApp";
    unreadTag.textContent = v.unread > 0 ? t("{0} unread", { 0: v.unread }) : "";
    unreadTag.style.display = v.unread > 0 && !showArchived ? "" : "none";
    clear(listBody);
    if (v.link.state !== "connected") {
      listBody.append(
        h("div", { class: "int-status" }, dot(linkColor(v.link), 5), h("span", { class: "wa-status-text", text: linkLabel(v.link) })),
        h("div", { class: "int-actions" }, h("button", {
          class: "link-btn wa-settings", text: t("Settings…"), onclick: () => host.openSettings(),
        })),
      );
      return;
    }
    const rows = shownChats.map(row);
    if (!showArchived && archivedCount > 0) rows.unshift(archivedRow(archivedCount));
    if (rows.length === 0) listBody.append(h("div", { class: "wa-empty", text: t("No new messages") }));
    else listBody.append(h("div", { class: "int-rows wa-rows" }, ...rows));
  }

  function syncConversation(c: WaConversation) {
    const v = WhatsApp.view;
    const all = shownMessages(c);
    const key = [language(), c.id, c.name, ...all.map((m) => m.id)].join("~");
    if (key !== convoKey) {
      const wasAtBottom = messages.scrollHeight - messages.scrollTop - messages.clientHeight < 24;
      const first = convoKey === "";
      convoKey = key;
      clear(convoAvatar);
      convoAvatar.append(avatar(c.name, c.isGroup, 20));
      convoName.textContent = c.name;
      convoName.title = c.id.split("@")[0];
      if (nodesLanguage !== language()) {
        nodesLanguage = language();
        nodes.clear();
        clear(messages);
      }
      // The bubbles already there stay (a video keeps playing); new ones go in their place.
      const wanted = all.map((m) => {
        let node = nodes.get(m.id);
        if (!node) {
          node = chatBubble(m, c.isGroup);
          nodes.set(m.id, node);
        }
        return node;
      });
      wanted.forEach((node, i) => {
        const at = messages.children[i] ?? null;
        if (at !== node) messages.insertBefore(node, at);
      });
      while (messages.children.length > wanted.length) messages.children[messages.children.length - 1].remove();
      // The newest at the bottom, in view.
      if (first || wasAtBottom) messages.scrollTop = messages.scrollHeight;
    }
    field.placeholder = t("Reply…  (Shift+Enter: new line)");
    reply.style.display = forwarding ? "none" : "";
    attached.style.display = attachment && !forwarding ? "" : "none";
    attachedName.textContent = attachment?.name ?? "";
    forwardBar.style.display = forwarding ? "" : "none";
    if (forwarding) {
      const to = forwardTo ? allChats().find((x) => x.id === forwardTo) : undefined;
      fwdText.textContent = to ? "" : t("Pick the chat to forward to");
      fwdSend.style.display = to ? "" : "none";
      fwdSend.textContent = to ? t("Forward to {name}", { name: to.name }) : "";
      fwdSend.disabled = v.sending;
    }
    note.className = "wa-note";
    if (localError) {
      note.textContent = sendErrorLabel(localError);
      note.classList.add("err");
    } else if (v.link.state !== "connected") {
      note.textContent = linkLabel(v.link);
      note.classList.add("warn");
    } else if (v.sendError) {
      note.textContent = sendErrorLabel(v.sendError);
      note.classList.add("err");
    } else {
      note.textContent = flash;
    }
    syncSendButton();
  }

  function sync() {
    if (!shown) {
      shown = true;
      void refreshChats();
    }
    // Only gone when WhatsApp is off or the chat left the list (ignored).
    if (openChat != null && (!current() || !WhatsApp.view.on)) close();
    const c = current();
    pick.style.display = c ? "none" : "";
    convo.style.display = c ? "" : "none";
    syncList(chatList(WhatsApp.view.conversations, gatewayChats, showArchived), chatList(WhatsApp.view.conversations, gatewayChats, true).length);
    if (c) syncConversation(c);
  }

  return {
    el,
    sync,
    focus() {
      if (openChat) field.focus();
    },
  };
}

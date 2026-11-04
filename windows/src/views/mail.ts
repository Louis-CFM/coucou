// The Mail card (classic Outlook) — a DOM port of MailCardView / MailRow / MailDetailView
// (MailViews.swift). Sizes, colours and wording are the Mac's.
//
// The list: the newest messages of every inbox, unread ones tinted, a flag on the important
// ones; a search (free words, from:, subject:) and quick filters (All, Unread, Important,
// Today); Load more. A click opens the message: its sender, subject and the start of its text,
// with Open in Outlook, Reply (Outlook's own window: nothing is sent from Coucou), Mark as read,
// Important, Junk, and in ⋯ Always important (VIP) and Always ignore this sender.
//
// Built once and synced in place: the search field keeps its text and the keyboard.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { State } from "../core/state";
import {
  MAIL_BLUE, MAIL_FILTERS, MAIL_ID, MailBridge, filterTitle, messageId, senderName,
  type MailCardData, type MailFilter, type MailMessage,
} from "../core/mail";
import { timeAgo } from "./integrations";
import { language, t, tl } from "../i18n/i18n";

export interface MailCardHost {
  /** The island takes the keyboard for the search field, and gives it back. */
  keyboard(on: boolean): void;
}

export interface MailCard {
  el: HTMLElement;
  sync(): void;
}

function data(): MailCardData {
  const d = (State.integrations[MAIL_ID]?.data ?? {}) as Partial<MailCardData>;
  return {
    running: d.running ?? false,
    windows: d.windows ?? true,
    unread: d.unread ?? 0,
    messages: Array.isArray(d.messages) ? d.messages : [],
    shown: d.shown ?? 12,
    maxShown: d.maxShown ?? 60,
  };
}

export function buildMailCard(host: MailCardHost): MailCard {
  const unreadTag = h("span", { class: "mail-unread" });
  const field = h("input", { class: "mail-search", type: "text", spellcheck: "false", placeholder: t("from:anne invoice") }) as HTMLInputElement;
  const closeSearch = h("button", { class: "mail-icon", title: tl("Close") }, svg(ICONS.xmark, 9));
  const searchBtn = h("button", { class: "mail-icon", title: tl("Search") }, svg(ICONS.magnifier, 10));
  const head = h("div", { class: "int-head mail-head" }, dot(MAIL_BLUE, 7), h("b", { text: "Outlook" }));
  const filters = h("div", { class: "mail-filters" });
  const listBody = h("div", { class: "mail-rows" });
  const listView = h("div", { class: "mail-list" }, head, filters, listBody);
  const detailView = h("div", { class: "mail-detail" });
  const el = h("div", { class: "int-card mail-card" }, listView, detailView);

  let searchOpen = false;
  let filter: MailFilter = "all";
  let results: MailMessage[] | null = null;
  let searching = false;
  let token = 0;
  let open: MailMessage | null = null;
  const previews = new Map<string, { text: string; attachments: string[] } | null>();
  let listKey = "";
  let refreshed = 0;

  const displayed = (): MailMessage[] => results ?? data().messages;

  async function runSearch() {
    const q = field.value.trim();
    if (!q && filter === "all") {
      results = null;
      searching = false;
      listKey = "";
      sync();
      return;
    }
    const mine = ++token;
    searching = true;
    listKey = "";
    sync();
    const found = await MailBridge.search(q, filter);
    if (mine !== token) return;
    searching = false;
    results = found ?? [];
    listKey = "";
    sync();
  }

  function setSearch(on: boolean) {
    searchOpen = on;
    if (on) {
      host.keyboard(true);
      window.setTimeout(() => field.focus(), 80);
    } else {
      field.value = "";
      filter = "all";
      results = null;
      token++;
      searching = false;
      host.keyboard(false);
    }
    listKey = "";
    sync();
  }

  searchBtn.addEventListener("click", () => setSearch(true));
  closeSearch.addEventListener("click", () => setSearch(false));
  field.addEventListener("keydown", (e) => {
    const key = (e as KeyboardEvent).key;
    if (key === "Enter") {
      e.preventDefault();
      void runSearch();
    } else if (key === "Escape") {
      e.preventDefault();
      setSearch(false);
    }
    e.stopPropagation();
  });

  function openMessage(m: MailMessage) {
    open = m;
    const id = messageId(m);
    if (!previews.has(id)) {
      previews.set(id, null);
      void MailBridge.detail(m).then((d) => {
        previews.set(id, d ?? { text: "", attachments: [] });
        drawDetail();
      });
    }
    drawDetail();
    sync();
  }

  function closeMessage() {
    open = null;
    listKey = "";
    sync();
  }

  async function act(m: MailMessage, kind: "read" | "flag" | "unflag" | "junk" | "ignore" | "vip") {
    // Shown at once; Outlook catches up.
    const id = messageId(m);
    const change = (list: MailMessage[] | null) =>
      list?.flatMap((x) => {
        if (messageId(x) !== id) return [x];
        if (kind === "junk" || kind === "ignore") return [];
        return [{ ...x, unread: kind === "read" ? false : x.unread, flagged: kind === "flag" || kind === "vip" ? true : kind === "unflag" ? false : x.flagged }];
      }) ?? null;
    results = change(results);
    if (open && messageId(open) === id) {
      open = kind === "junk" || kind === "ignore" ? null : change([open])?.[0] ?? null;
    }
    listKey = "";
    sync();
    await MailBridge.act(m, kind);
  }

  function row(m: MailMessage): HTMLElement {
    const r = h("button", { class: m.unread ? "int-row mail-row unread" : "int-row mail-row" },
      h("i", { class: m.unread ? "mail-dot on" : "mail-dot" }),
      h("span", { class: "int-name mail-name", text: senderName(m) }),
    );
    if (m.flagged) r.append(h("span", { class: "mail-flag", text: "⚑" }));
    r.append(
      h("span", { class: "int-ago", text: timeAgo(m.date) }),
      h("span", { class: "int-sub mail-subject", text: m.subject }),
    );
    r.addEventListener("click", () => openMessage(m));
    return r;
  }

  function syncList() {
    const d = data();
    const list = displayed();
    const key = [
      language(), d.running, d.windows, d.unread, searchOpen, filter, searching, results === null, d.shown,
      Math.floor(Date.now() / 60_000),
      ...list.map((m) => `${messageId(m)}|${m.unread}|${m.flagged}`),
    ].join("~");
    if (key === listKey) return;
    listKey = key;

    // The head: the unread count and the magnifier, or the search field.
    clear(head);
    head.append(dot(MAIL_BLUE, 7), h("b", { text: "Outlook" }));
    if (searchOpen) {
      head.append(field);
      if (searching) head.append(h("span", { class: "mail-spinner" }));
      head.append(closeSearch);
    } else {
      head.append(h("span", { text: t("Inbox") }));
      // Just the number, on one line (the sentence on hover).
      unreadTag.textContent = d.unread > 9999 ? "9999+" : String(d.unread);
      unreadTag.title = t("{0} unread", { 0: d.unread });
      unreadTag.style.display = d.unread > 0 ? "" : "none";
      head.append(unreadTag, h("span", { class: "mail-spacer" }));
      if (searching) head.append(h("span", { class: "mail-spinner" }));
      head.append(searchBtn);
    }

    clear(filters);
    for (const f of MAIL_FILTERS) {
      filters.append(h("button", {
        class: f === filter ? "mail-chip on" : "mail-chip",
        text: filterTitle(f),
        onclick: () => {
          filter = f;
          void runSearch();
        },
      }));
    }
    filters.style.display = d.running ? "" : "none";

    clear(listBody);
    if (!d.windows) {
      listBody.append(h("div", { class: "mail-empty", text: t("Outlook is only reached on Windows.") }));
      return;
    }
    if (!d.running) {
      listBody.append(h("div", { class: "mail-empty", text: t("Open Outlook (the classic one) to see your mail here.") }));
      return;
    }
    if (list.length === 0) {
      listBody.append(h("div", { class: "mail-empty", text: results !== null ? t("Nothing found") : t("No messages") }));
      return;
    }
    for (const m of list) listBody.append(row(m));
    if (results === null && d.messages.length >= d.shown && d.shown < d.maxShown) {
      listBody.append(h("button", { class: "link-btn mail-more", text: t("Load more"), onclick: () => void MailBridge.more() }));
    }
  }

  function drawDetail() {
    clear(detailView);
    const m = open;
    if (!m) return;
    const back = h("button", { class: "int-back mail-back", title: tl("Back") }, svg(ICONS.chevronLeft, 10, { stroke: 2.4 }));
    back.addEventListener("click", closeMessage);
    const preview = previews.get(messageId(m));
    const text = preview === undefined || preview === null ? t("Loading…") : preview.text.trim() || " ";
    const actions = h("div", { class: "mail-actions" },
      h("button", { class: "link-btn accent", text: t("Open in Outlook"), onclick: () => void MailBridge.open(m, false) }),
      h("button", { class: "link-btn", text: t("Reply"), onclick: () => void MailBridge.open(m, true) }),
    );
    if (m.unread) actions.append(h("button", { class: "link-btn dim", text: t("Mark as read"), onclick: () => void act(m, "read") }));
    actions.append(
      h("button", {
        class: "link-btn amber",
        text: m.flagged ? t("Not important") : t("Important"),
        onclick: () => void act(m, m.flagged ? "unflag" : "flag"),
      }),
      h("button", { class: "link-btn dim", text: t("Junk"), onclick: () => void act(m, "junk") }),
    );
    // ⋯: Always important (VIP), Always ignore this sender.
    const more = h("div", { class: "mail-more-menu" });
    const dots = h("button", { class: "link-btn dim mail-dots", text: "⋯" });
    dots.addEventListener("click", () => more.classList.toggle("on"));
    more.append(
      h("button", { text: t("Always important (VIP)"), onclick: () => void act(m, "vip") }),
      h("button", { text: t("Always ignore this sender"), onclick: () => void act(m, "ignore") }),
    );
    actions.append(h("span", { class: "mail-dots-wrap" }, dots, more));
    detailView.append(
      h("div", { class: "mail-detail-head" },
        back,
        h("i", { class: m.unread ? "mail-dot on" : "mail-dot" }),
        h("b", { class: "mail-from", text: senderName(m), title: m.address }),
        h("span", { class: "mail-spacer" }),
        h("span", { class: "int-ago", text: timeAgo(m.date) }),
      ),
      h("div", { class: "mail-detail-subject", text: m.subject || " " }),
      h("div", { class: "mail-detail-text", text }),
      actions,
    );
  }

  function sync() {
    el.classList.toggle("detail-open", open !== null);
    if (open) {
      // The open message, kept up to date when a refresh changes it.
      const fresh = displayed().find((x) => messageId(x) === messageId(open!));
      if (fresh && (fresh.unread !== open.unread || fresh.flagged !== open.flagged)) {
        open = fresh;
        drawDetail();
      }
    }
    syncList();
    // Opening the card reads Outlook again (at most every 15 s).
    if (State.focusTask?.id === MAIL_ID && State.mode === "expanded" && Date.now() - refreshed > 15_000) {
      refreshed = Date.now();
      void MailBridge.refresh();
    }
  }

  // Leaving the card gives the keyboard back.
  State.subscribe(() => {
    if (!searchOpen) return;
    if (State.mode !== "expanded" || State.view !== "overview" || State.focusTask?.id !== MAIL_ID) setSearch(false);
  });

  return { el, sync };
}

// The Mail section of the Coucou window (classic Outlook): the automatic sorting and its
// journal, the rules, the banned words and the VIPs. Port of MailHubPages.swift; what they
// decide lives in src-tauri/src/mail/triage.rs.

import { h, clear } from "../../views/dom";
import { t } from "../../i18n/i18n";
import {
  MAIL_BLUE, MAIL_FIELDS, MailBridge, fieldTitle, journalLine, nameOf, reasonLine, ruleLine, ruleName,
  type MailAction, type MailField, type MailSettings, type TriageView,
} from "../../core/mail";
import type { HubContext } from "../shell";
import { emptyState } from "../hero";
import { button, card, divider, icon, iconButton, label, row, select, toggle } from "../ui";

const EMPTY: TriageView = {
  settings: { autoSort: false, autoSortSince: null, banned: [], vip: [], rules: [] },
  journal: [], sent: [], today: { sorted: 0, junk: 0, important: 0 }, windows: true, outlookOpen: false,
};

async function load(): Promise<TriageView> {
  return (await MailBridge.triage()) ?? EMPTY;
}

function save(settings: MailSettings) {
  void MailBridge.setTriage(settings);
}

function input(placeholder: string, onEnter?: () => void): HTMLInputElement {
  const el = h("input", { class: "hub-input", placeholder }) as HTMLInputElement;
  if (onEnter) el.addEventListener("keydown", (e) => e.key === "Enter" && onEnter());
  el.style.flex = "1";
  return el;
}

function time(ms: number, withDay = false): string {
  try {
    return new Intl.DateTimeFormat(document.documentElement.lang || undefined, withDay
      ? { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }
      : { hour: "2-digit", minute: "2-digit" }).format(new Date(ms));
  } catch {
    return new Date(ms).toLocaleTimeString();
  }
}

/** When the automatic sorting is off, the pages that feed it say so, with the switch. */
function autoSortHint(view: TriageView, redraw: () => void): HTMLElement | null {
  if (view.settings.autoSort) return null;
  return card(row(t("Automatic sorting is off: these settings do nothing until it is on."), null,
    button(t("Turn on"), () => {
      save({ ...view.settings, autoSort: true });
      window.setTimeout(redraw, 300);
    }, "primary")));
}

// ── Overview ─────────────────────────────────────────────────────────────────

export async function mailOverviewPage(page: HTMLElement, ctx: HubContext) {
  const view = await load();
  page.append(ctx.hero("mailOverview", t("Overview"),
    t("Coucou sorts your Outlook inboxes: VIPs first, then banned words, then your rules. It never deletes a message.")));
  const redraw = () => ctx.navigate("mailOverview");

  const sortCard = card(row(t("Sort new messages automatically"),
    t("Only messages that arrive from now on, in every Outlook account. The classic Outlook must be open."),
    toggle(view.settings.autoSort, (on) => {
      save({ ...view.settings, autoSort: on });
      view.settings.autoSort = on;
    })));
  if (!view.windows) {
    sortCard.append(divider(), h("div", { class: "hub-note", text: t("Outlook is only reached on Windows.") }));
  } else if (!view.outlookOpen) {
    sortCard.append(divider(), h("div", { class: "hub-note", text: t("Outlook is closed: nothing is sorted until it is open.") }));
  }
  sortCard.dataset.anchor = "mail.autosort";
  page.append(sortCard);

  const stat = (value: number, text: string, color: string) =>
    card(h("div", { class: "mail-stat", style: `color:${color}`, text: String(value) }), h("div", { class: "hub-note", text }));
  page.append(h("div", { class: "mail-stats" },
    stat(view.today.sorted, t("sorted today"), MAIL_BLUE),
    stat(view.today.junk, t("sent to Junk"), "#8E939C"),
    stat(view.today.important, t("marked important"), "#F5A524"),
  ));

  if (view.sent.length > 0) {
    page.append(label(t("Sent by Coucou")));
    const list = card();
    view.sent.forEach((e, i) => {
      if (i > 0) list.append(divider());
      list.append(h("div", { class: "hub-list-row mail-journal" },
        h("b", { text: e.to.join(", ") }),
        h("span", { class: "grow mail-dim", text: e.subject }),
        e.attachments.length > 0 ? h("span", { class: "mail-dim", text: `📎 ${e.attachments.join(", ")}` }) : h("span"),
        h("span", { class: "mail-dim", text: time(e.date, true) }),
      ));
    });
    page.append(list);
  }

  const journalHead = h("div", { class: "hub-row" }, label(t("Journal")));
  if (view.journal.length > 0) {
    journalHead.append(button(t("Clear"), () => {
      void MailBridge.clearJournal().then(redraw);
    }, "", true));
  }
  page.append(journalHead);
  const journal = card();
  if (view.journal.length === 0) {
    journal.append(emptyState(t("Nothing sorted yet. What Coucou does to your messages shows up here, with an Undo."), "idle", MAIL_BLUE));
  }
  view.journal.forEach((e, i) => {
    if (i > 0) journal.append(divider());
    const undo = e.undone
      ? h("span", { class: "mail-dim", text: t("Undone") })
      : button(t("Undo"), () => void MailBridge.undo(e.id).then(redraw), "", true);
    journal.append(h("div", { class: "hub-list-row mail-journal" },
      h("div", { class: "grow" },
        h("div", {}, h("b", { text: nameOf(e.sender) }), h("span", { class: "mail-dim", text: `  ${e.subject}` })),
        h("div", { class: "mail-dim small", text: `${journalLine(e.action)} · ${reasonLine(e.reason)}` }),
      ),
      h("span", { class: "mail-dim", text: time(e.date) }),
      undo,
    ));
  });
  page.append(journal);
}

// ── Rules ────────────────────────────────────────────────────────────────────

type Kind = "junk" | "important" | "read" | "move";

export async function mailRulesPage(page: HTMLElement, ctx: HubContext) {
  const view = await load();
  const redraw = () => ctx.navigate("mailRules");
  page.append(ctx.hero("mailRules", t("Rules"),
    t("If a message matches, Coucou does the action. The first rule that matches wins; VIPs and banned words come before.")));
  const hint = autoSortHint(view, redraw);
  if (hint) page.append(hint);

  let field: MailField = "sender";
  let kind: Kind = "junk";
  const value = input(t("newsletter, @shop.com, invoice…"), () => add());
  const mailbox = input(t("Mailbox name"), () => add());
  mailbox.style.display = "none";
  const action = (): MailAction | null => {
    switch (kind) {
      case "junk": return { kind: "junk" };
      case "important": return { kind: "important" };
      case "read": return { kind: "markRead" };
      case "move": return mailbox.value.trim() ? { kind: "move", mailbox: mailbox.value.trim() } : null;
    }
  };
  const add = () => {
    const v = value.value.trim();
    const a = action();
    if (!v || !a) return;
    const rules = [...view.settings.rules, {
      id: `${Date.now().toString(16)}-${Math.random().toString(16).slice(2, 8)}`,
      name: ruleName(field, v, a), enabled: true, conditions: [{ field, value: v }], action: a,
    }];
    view.settings = { ...view.settings, rules };
    save(view.settings);
    value.value = "";
    mailbox.value = "";
    drawRules();
  };
  const fields = select(MAIL_FIELDS.map((f) => [f, fieldTitle(f)] as [MailField, string]), field, (f) => (field = f));
  const kinds = select<Kind>([
    ["junk", ruleLine({ kind: "junk" })],
    ["important", ruleLine({ kind: "important" })],
    ["read", ruleLine({ kind: "markRead" })],
    ["move", t("Move to mailbox…")],
  ], kind, (k) => {
    kind = k;
    mailbox.style.display = k === "move" ? "" : "none";
  });
  page.append(card(
    h("div", { class: "hub-row mail-rule-line" }, h("b", { class: "mail-if", text: t("If") }), fields, h("span", { class: "mail-dim", text: t("contains") }), value),
    h("div", { class: "hub-row mail-rule-line" }, h("b", { class: "mail-if", text: t("Then") }), kinds, mailbox, h("span", { class: "grow" }), button(t("Add"), add, "primary")),
  ));

  const list = card();
  list.dataset.anchor = "mail.rules";
  page.append(list);
  const drawRules = () => {
    clear(list);
    if (view.settings.rules.length === 0) {
      list.append(emptyState(t("No rules yet. Example: if the sender contains “newsletter”, move to Junk."), "idle", "#34D399"));
      return;
    }
    view.settings.rules.forEach((r, i) => {
      if (i > 0) list.append(divider());
      list.append(h("div", { class: "hub-list-row" },
        toggle(r.enabled, (on) => {
          view.settings = { ...view.settings, rules: view.settings.rules.map((x) => (x.id === r.id ? { ...x, enabled: on } : x)) };
          save(view.settings);
        }),
        h("span", { class: "grow", text: r.name }),
        iconButton("trash", t("Delete"), () => {
          view.settings = { ...view.settings, rules: view.settings.rules.filter((x) => x.id !== r.id) };
          save(view.settings);
          drawRules();
        }),
      ));
    });
  };
  drawRules();
}

// ── Banned words and VIPs ────────────────────────────────────────────────────

function chipsPage(
  page: HTMLElement, ctx: HubContext, view: TriageView, id: "mailBanned" | "mailVIP",
  key: "banned" | "vip", placeholder: string, empty: string, color: string,
) {
  const hint = autoSortHint(view, () => ctx.navigate(id));
  if (hint) page.append(hint);
  const chips = h("div", { class: "hub-chips" });
  const field = input(placeholder, () => add());
  const add = () => {
    const w = field.value.trim();
    const list = view.settings[key];
    if (!w || list.some((x) => x.toLowerCase() === w.toLowerCase())) return;
    view.settings = { ...view.settings, [key]: [...list, w] };
    save(view.settings);
    field.value = "";
    draw();
  };
  const draw = () => {
    clear(chips);
    const list = view.settings[key];
    if (list.length === 0) {
      chips.append(emptyState(empty, "idle", color));
      return;
    }
    for (const w of list) {
      const remove = h("button", { title: t("Delete"), "aria-label": t("Delete") });
      remove.append(icon("x"));
      remove.addEventListener("click", () => {
        view.settings = { ...view.settings, [key]: view.settings[key].filter((x) => x !== w) };
        save(view.settings);
        draw();
      });
      chips.append(h("span", { class: "hub-chip" }, h("span", { text: w }), remove));
    }
  };
  const chipsCard = card(h("div", { class: "hub-row" }, field, button(t("Add"), add, "primary")), chips);
  chipsCard.dataset.anchor = id === "mailBanned" ? "mail.banned" : "mail.vip";
  page.append(chipsCard);
  draw();
}

export async function mailBannedPage(page: HTMLElement, ctx: HubContext) {
  const view = await load();
  page.append(ctx.hero("mailBanned", t("Banned words"),
    t("A message whose sender, subject or text holds one of these words or addresses goes straight to Junk. Whole words only: “sale” does not catch “Salesforce”.")));
  chipsPage(page, ctx, view, "mailBanned", "banned", t("A word, a phrase or an address"),
    t("No banned words. Add a word, or click “Always ignore this sender” on a message in the island."), "#FF453A");
}

export async function mailVIPPage(page: HTMLElement, ctx: HubContext) {
  const view = await load();
  page.append(ctx.hero("mailVIP", t("VIP"),
    t("Messages from these addresses or domains are always flagged important, and no rule ever moves them.")));
  chipsPage(page, ctx, view, "mailVIP", "vip", t("paul@client.com or @client.com"),
    t("No VIPs yet. Add an address, or a whole domain with @."), "#F5A524");
}

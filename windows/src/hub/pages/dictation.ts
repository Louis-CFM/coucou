// Dictation: today's dictations with search and copy, the big numbers, and the
// way to the Notetaker. Until dictation is set up, the steps to get there.
// Port of FlowHubHome.swift.

import { h, clear } from "../../views/dom";
import { t } from "../../i18n/i18n";
import { onEvent } from "../../core/bridge";
import { FlowBridge, type FlowEntry, type FlowStats } from "../../core/flow";
import type { HubContext } from "../shell";
import { emptyState, glowCard } from "../hero";
import { button, card, icon, iconButton, keyLabel, label, number, row, shortCount, toggle } from "../ui";
import { modelsControl } from "./flowsettings";

function dayKey(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
}

function dayTitle(ms: number): string {
  const today = new Date();
  const yesterday = new Date(Date.now() - 86_400_000);
  if (dayKey(ms) === dayKey(today.getTime())) return t("Today");
  if (dayKey(ms) === dayKey(yesterday.getTime())) return t("Yesterday");
  return new Date(ms).toLocaleDateString(document.documentElement.lang || undefined, { weekday: "long", day: "numeric", month: "long" });
}

function time(ms: number): string {
  return new Date(ms).toLocaleTimeString(document.documentElement.lang || undefined, { hour: "2-digit", minute: "2-digit" });
}

export async function dictationPage(page: HTMLElement, ctx: HubContext) {
  const status = ctx.status;
  const key = keyLabel(status.keys === "wayland" ? "wayland" : status.prefs.key, status.platform);
  const ready = status.prefs.enabled && status.models.parakeet.state === "ready";

  const record = button(t("Record a call"), () => {
    void FlowBridge.startNote().then(() => ctx.navigate("notes"), (err) => alertLine.replaceChildren(String(err)));
  }, "primary");
  record.prepend(h("span", { class: "hub-rec", style: "background:#170c04;box-shadow:none;margin-inline-end:8px" }));
  const alertLine = h("div", { class: "hub-note" });
  const hello = status.userName ? t("Hello {0}", { 0: status.userName }) : t("Hello");
  page.append(ctx.hero("dictation", hello, t("Hold {0} anywhere, speak, let go: it's pasted.", { 0: key }), [record]));
  page.append(alertLine);

  if (!ready) page.append(setup(ctx));

  const [history, stats] = await Promise.all([FlowBridge.history(), FlowBridge.stats()]);
  let entries: FlowEntry[] = history ?? [];
  let query = "";

  const list = h("div", { style: "display:flex;flex-direction:column;gap:10px" });
  const search = h("input", { class: "hub-input", placeholder: t("Search dictations"), type: "search" }) as HTMLInputElement;
  search.addEventListener("input", () => {
    query = search.value.trim().toLowerCase();
    draw();
  });

  function draw() {
    clear(list);
    if (status.prefs.keepDays === 0) {
      list.append(emptyState(t("The history is off. Turn it on in Settings → Privacy.")));
      return;
    }
    const shown = query ? entries.filter((e) => e.text.toLowerCase().includes(query)) : entries;
    if (shown.length === 0) {
      list.append(emptyState(query ? t("No dictation matches.") : t("Your dictations will show here. Hold {0} in any app and speak.", { 0: key })));
      return;
    }
    let group: HTMLElement | null = null;
    let groupDay = "";
    for (const e of shown.slice(0, 300)) {
      const d = dayKey(e.date);
      if (d !== groupDay) {
        groupDay = d;
        list.append(h("div", { class: "hub-day", text: dayTitle(e.date) }));
        group = h("div", { class: "hub-entries" });
        list.append(group);
      }
      const when = h("div", { class: "when" }, h("span", { text: time(e.date) }));
      if (e.app) when.append(h("span", { class: "hub-tag", text: e.app, title: e.app }));
      const tools = h("div", { class: "tools" },
        iconButton("copy", t("Copy"), () => void FlowBridge.copy(e.text)),
        iconButton("trash", t("Delete"), () => {
          entries = entries.filter((x) => x.id !== e.id);
          void FlowBridge.deleteEntry(e.id);
          draw();
        }),
      );
      group!.append(h("div", { class: "hub-entry" }, when, h("div", { class: "words", text: e.text }), tools));
    }
  }

  const left = h("div", { style: "display:flex;flex-direction:column;gap:10px;min-width:0" },
    h("div", { class: "hub-history-head" }, label(t("History")), search),
    list,
  );
  const right = h("div", { style: "display:flex;flex-direction:column;gap:14px" }, numbers(stats), promo(ctx));
  page.append(h("div", { class: "hub-columns" }, left, right));
  draw();

  const unlisten = await onEvent<FlowEntry | null>("flow-history", (entry) => {
    if (!entry) return;
    entries = [entry, ...entries.filter((x) => x.id !== entry.id)];
    draw();
    void FlowBridge.stats().then((s) => right.firstElementChild?.replaceWith(numbers(s)));
  });
  ctx.onLeave = () => unlisten();
}

function numbers(stats: FlowStats | null): HTMLElement {
  const all = stats?.all;
  const big = (value: string, text: string) => h("div", { class: "hub-big-number" }, h("b", { text: value }), h("span", { text }));
  const ok = h("div", { class: "hub-ok" });
  ok.append(icon("check"), h("span", { text: t("Unlimited and free") }));
  ok.querySelector("svg")!.setAttribute("style", "width:15px;height:15px;fill:none;stroke:currentColor;stroke-width:2.2");
  return card(
    big(shortCount(all?.words ?? 0), t("words dictated")),
    big(number(all?.wordsPerMinute ?? 0), t("words/min")),
    big(number(stats?.streak ?? 0), t("days in a row")),
    h("div", { class: "hub-divider" }),
    ok,
  );
}

function promo(ctx: HubContext): HTMLElement {
  return glowCard(
    "#FB923C",
    h("div", { style: "font:700 15px var(--font)", text: t("The Notetaker") }),
    h("div", { class: "hub-note", style: "color:#b7bbc2", text: t("Your calls transcribed person by person, with a summary and the to-dos. No bot in the meeting.") }),
    h("button", { class: "hub-link", text: t("Open the Notetaker →"), onclick: () => ctx.navigate("notes") }),
  );
}

/** Until dictation works: turn it on, download the model. */
function setup(ctx: HubContext): HTMLElement {
  const status = ctx.status;
  const key = keyLabel(status.keys === "wayland" ? "wayland" : status.prefs.key, status.platform);
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  body.append(
    h("div", { style: "font:700 17px var(--font)", text: t("Dictate anywhere on your computer") }),
    h("div", { class: "hub-note", style: "color:#b7bbc2;font-size:13px", text: t("Hold {0} in any app, speak, let go: your words are pasted where you type.", { 0: key }) }),
  );
  body.append(row(t("Turn on dictation"), null, toggle(status.prefs.enabled, (on) => {
    void ctx.setPrefs((p) => (p.enabled = on)).then(() => ctx.navigate("dictation"));
  })));
  body.append(row(t("Parakeet, on your computer"), t("The most accurate, offline, 25 languages. Downloaded once (about {0} MB).", { 0: number(status.models.downloadMb) }), modelsControl(ctx, () => ctx.navigate("dictation"))));
  return glowCard("#FB923C", body);
}

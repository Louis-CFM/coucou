// The Kit page: four small tools in one tab — a focus timer, a water
// reminder, a to-do list with reminders and a file shelf (core/kit.ts for the
// rules, core/kitstore.ts for the state and the reminders' clock). Mochi sits
// small on the left as on the Clipboard page; the tools' tabs run along the top.

import { h, clear, svg } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type KitFileInfo } from "../core/bridge";
import { State } from "../core/state";
import {
  clock, dueFromTime, focusToday, leftOf, size, sortedTodos, waterToday, waterWeek, type KitPage,
} from "../core/kit";
import { Kit } from "../core/kitstore";
import { t } from "../i18n/i18n";
import type { ViewActions, ViewHost } from "./views";
import { buildPrayerPage, prayerLabel } from "./prayer";

export const KIT_ICONS = {
  water: "M12 3.2c3.3 4.1 6 7.6 6 10.9a6 6 0 0 1-12 0c0-3.3 2.7-6.8 6-10.9z",
  checklist: "M4 6.5l1.6 1.6L8.4 5.3M4 12.5l1.6 1.6 2.8-2.8M4 18.5l1.6 1.6 2.8-2.8M11.5 7H20M11.5 13H20M11.5 19H20",
  shelf: "M3.5 13.5h4.6l1.5 2.6h4.8l1.5-2.6h4.6M5.4 5h13.2l1.9 8.5v5.5h-17v-5.5z",
  kit: "M4.5 4.5h6v6h-6zM13.5 4.5h6v6h-6zM4.5 13.5h6v6h-6zM13.5 13.5h6v6h-6z",
  reveal: "M3 6.6a2 2 0 0 1 2-2h4.3l2 2.2H19a2 2 0 0 1 2 2v8.6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6.6zM12 11v5M9.6 13.6 12 11l2.4 2.6",
  skip: "M6 5.5v13l9-6.5zM17.5 5.5v13",
  stop: "M6.5 6.5h11v11h-11z",
  moon: "M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z",
  bell: "M6.5 16.5V11a5.5 5.5 0 0 1 11 0v5.5l1.5 1.5H5zM10 20.2a2.2 2.2 0 0 0 4 0",
};

function icon(path: string, size = 14, stroke = 1.9): SVGSVGElement {
  return svg(path, size, { stroke });
}

function button(label: string, cls: string, onClick: () => void, iconPath?: string): HTMLButtonElement {
  return h("button", {
    class: `kit-btn ${cls}`.trim(),
    onclick: (e: Event) => {
      e.stopPropagation();
      onClick();
    },
  }, iconPath ? icon(iconPath, 12, 2) : null, label ? h("span", { text: label }) : null) as HTMLButtonElement;
}

/** −  value  + */
function stepper(read: () => string, minus: () => void, plus: () => void, title: string): { el: HTMLElement; sync(): void } {
  const value = h("span", { class: "kit-step-v" });
  const el = h("div", { class: "kit-step", title },
    button("", "kit-step-b", minus, ICONS.minus),
    value,
    button("", "kit-step-b", plus, ICONS.plus));
  return { el, sync: () => { const v = read(); if (value.textContent !== v) value.textContent = v; } };
}

const PAGES: [KitPage, string, () => string][] = [
  ["focus", ICONS.timer, () => t("Focus")],
  ["water", KIT_ICONS.water, () => t("Water")],
  ["todo", KIT_ICONS.checklist, () => t("To-do")],
  ["shelf", KIT_ICONS.shelf, () => t("Shelf")],
  ["prayer", KIT_ICONS.moon, () => t("Prayer")],
];

export function buildKit(actions: ViewActions): ViewHost {
  Kit.setTexts(
    { work: t("Focus"), break: t("Break"), long: t("Long break") },
    {
      workDone: t("Round done. Time for a break."),
      breakDone: t("Break's over. Back to focus."),
      longDone: t("Focus session complete. Well done!"),
      water: t("Time for some water."),
    },
  );

  Kit.setPrayerTexts(
    (name, min) => t("{prayer} in {min} min", { prayer: prayerLabel(name), min }),
    (name) => t("It's time for {prayer}", { prayer: prayerLabel(name) }),
  );

  // ── Top: the tools' tabs and the reminder banner ──
  const tabs = PAGES.map(([p, path, label]) => {
    const b = h("button", { class: "kit-tab", onclick: () => Kit.setPage(p) }, icon(path, 13), h("span", { text: label() }));
    return { p, b };
  });
  const bannerText = h("span", { class: "kit-banner-t" });
  const banner = h("div", { class: "kit-banner" },
    icon(KIT_ICONS.bell, 12, 2), bannerText,
    h("button", { class: "kit-banner-x", title: t("Dismiss"), onclick: () => Kit.dismissBanner() }, icon(ICONS.xmark, 10, 2)));
  const bar = h("div", { class: "kit-bar" }, ...tabs.map((x) => x.b), h("div", { class: "grow" }), banner);

  // ── Focus ──
  const R = 34;
  const C = 2 * Math.PI * R;
  const ringFg = document.createElementNS("http://www.w3.org/2000/svg", "circle");
  const ring = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  ring.setAttribute("viewBox", "0 0 80 80");
  ring.setAttribute("class", "kit-ring");
  const ringBg = document.createElementNS("http://www.w3.org/2000/svg", "circle");
  for (const c of [ringBg, ringFg]) {
    c.setAttribute("cx", "40");
    c.setAttribute("cy", "40");
    c.setAttribute("r", String(R));
  }
  ringBg.setAttribute("class", "kit-ring-bg");
  ringFg.setAttribute("class", "kit-ring-fg");
  ringFg.setAttribute("stroke-dasharray", String(C));
  ring.append(ringBg, ringFg);
  const focusTime = h("div", { class: "kit-ring-time" });
  const focusPhase = h("div", { class: "kit-ring-phase" });
  const dots = h("div", { class: "kit-dots" });
  const focusStats = h("div", { class: "kit-sub" });
  const focusBtns = h("div", { class: "kit-row" });
  const work = stepper(() => `${Kit.data.focus.workMin} min`, () => Kit.setFocus({ workMin: Kit.data.focus.workMin - 5 }),
    () => Kit.setFocus({ workMin: Kit.data.focus.workMin + 5 }), t("Focus length"));
  const brk = stepper(() => `${Kit.data.focus.breakMin} min`, () => Kit.setFocus({ breakMin: Kit.data.focus.breakMin - 1 }),
    () => Kit.setFocus({ breakMin: Kit.data.focus.breakMin + 1 }), t("Break length"));
  const rounds = stepper(() => `×${Kit.data.focus.rounds}`, () => Kit.setFocus({ rounds: Kit.data.focus.rounds - 1 }),
    () => Kit.setFocus({ rounds: Kit.data.focus.rounds + 1 }), t("Rounds before the long break"));
  const focusPage = h("div", { class: "kit-page kit-focus" },
    h("div", { class: "kit-ringbox" }, ring, h("div", { class: "kit-ring-in" }, focusTime, focusPhase)),
    h("div", { class: "kit-col" },
      dots,
      focusBtns,
      h("div", { class: "kit-row kit-prefs" },
        h("span", { class: "kit-lbl", text: t("Focus") }), work.el,
        h("span", { class: "kit-lbl", text: t("Break") }), brk.el,
        rounds.el),
      focusStats));
  let focusKey = "";

  function syncFocus(now: number) {
    const run = Kit.run;
    const p = Kit.data.focus;
    const total = (run.phase === "work" ? p.workMin : run.phase === "break" ? p.breakMin : run.phase === "long" ? p.longMin : p.workMin) * 60_000;
    const left = run.phase === "idle" ? total : leftOf(run, now);
    const text = clock(left);
    if (focusTime.textContent !== text) focusTime.textContent = text;
    ringFg.setAttribute("stroke-dashoffset", String(C * (1 - (total > 0 ? left / total : 0))));
    ring.dataset.phase = run.phase;
    const phase = run.phase === "idle" ? t("Ready") : run.phase === "work" ? t("Focus") : run.phase === "break" ? t("Break") : t("Long break");
    if (focusPhase.textContent !== phase) focusPhase.textContent = run.endsAt == null && run.phase !== "idle" ? `${phase} · ${t("Paused")}` : phase;
    const key = `${run.phase}|${run.round}|${run.endsAt == null}|${p.rounds}`;
    if (key !== focusKey) {
      focusKey = key;
      clear(dots);
      for (let i = 1; i <= p.rounds; i++) {
        const done = i < run.round || (i === run.round && run.phase !== "work" && run.phase !== "idle");
        dots.append(h("i", { class: `kit-dot${done ? " done" : ""}${i === run.round && run.phase === "work" ? " now" : ""}` }));
      }
      clear(focusBtns);
      if (run.phase === "idle") focusBtns.append(button(t("Start focus"), "primary", () => Kit.focusStart(), ICONS.play));
      else {
        focusBtns.append(
          run.endsAt == null
            ? button(t("Resume"), "primary", () => Kit.focusResume(), ICONS.play)
            : button(t("Pause"), "", () => Kit.focusPause(), ICONS.pause),
          button(t("Skip"), "", () => Kit.focusSkip(), KIT_ICONS.skip),
          button(t("Stop"), "", () => Kit.focusStop(), KIT_ICONS.stop),
        );
      }
    }
    for (const s of [work, brk, rounds]) s.sync();
    const stats = t("Today: {min} min of focus", { min: focusToday(Kit.data.focus, now) });
    if (focusStats.textContent !== stats) focusStats.textContent = stats;
  }

  // ── Water ──
  const waterFill = h("div", { class: "kit-glass-fill" });
  const waterAmount = h("div", { class: "kit-big" });
  const waterSub = h("div", { class: "kit-sub" });
  const chart = h("div", { class: "kit-chart" });
  const goal = stepper(() => `${(Kit.data.water.goalMl / 1000).toFixed(2).replace(/0$/, "")} L`,
    () => Kit.setWater({ goalMl: Kit.data.water.goalMl - 250 }), () => Kit.setWater({ goalMl: Kit.data.water.goalMl + 250 }), t("Daily goal"));
  const sip = stepper(() => `${Kit.data.water.sipMl} ml`,
    () => Kit.setWater({ sipMl: Kit.data.water.sipMl - 50 }), () => Kit.setWater({ sipMl: Kit.data.water.sipMl + 50 }), t("One drink"));
  const every = stepper(() => `${Kit.data.water.everyMin} min`,
    () => Kit.setWater({ everyMin: Kit.data.water.everyMin - 15 }), () => Kit.setWater({ everyMin: Kit.data.water.everyMin + 15 }), t("Remind every"));
  const remindBox = h("input", { type: "checkbox", class: "kit-check" }) as HTMLInputElement;
  remindBox.addEventListener("change", () => Kit.setWater({ remind: remindBox.checked }));
  const drinkBtn = button("", "primary", () => Kit.drink(), KIT_ICONS.water);
  const waterPage = h("div", { class: "kit-page kit-water" },
    h("div", { class: "kit-glass" }, waterFill),
    h("div", { class: "kit-col" },
      h("div", { class: "kit-row" }, waterAmount, h("div", { class: "grow" }), chart),
      waterSub,
      h("div", { class: "kit-row" }, drinkBtn, button(t("Undo"), "", () => Kit.undoDrink())),
      h("div", { class: "kit-row kit-prefs" },
        h("span", { class: "kit-lbl", text: t("Goal") }), goal.el,
        h("span", { class: "kit-lbl", text: t("Drink") }), sip.el,
        h("label", { class: "kit-lbl kit-remind" }, remindBox, h("span", { text: t("Remind") })), every.el)));
  let chartKey = "";

  function syncWater(now: number) {
    const w = Kit.data.water;
    const today = waterToday(w, now);
    const pct = Math.min(100, Math.round((today / w.goalMl) * 100));
    waterFill.style.height = `${pct}%`;
    const amount = `${(today / 1000).toFixed(2).replace(/0$/, "")} / ${(w.goalMl / 1000).toFixed(2).replace(/0$/, "")} L`;
    if (waterAmount.textContent !== amount) waterAmount.textContent = amount;
    const sub = pct >= 100 ? t("Today · {pct}% · Goal reached", { pct }) : t("Today · {pct}%", { pct });
    if (waterSub.textContent !== sub) waterSub.textContent = sub;
    const drinkLabel = t("Drink {ml} ml", { ml: w.sipMl });
    const span = drinkBtn.querySelector("span") ?? drinkBtn.appendChild(h("span", {}));
    if (span.textContent !== drinkLabel) span.textContent = drinkLabel;
    remindBox.checked = w.remind;
    for (const s of [goal, sip, every]) s.sync();
    const week = waterWeek(w, now);
    const key = week.join(",") + "|" + w.goalMl;
    if (key !== chartKey) {
      chartKey = key;
      clear(chart);
      const top = Math.max(w.goalMl, ...week);
      week.forEach((ml, i) => {
        const b = h("i", { class: `kit-bar-d${i === 6 ? " today" : ""}${ml >= w.goalMl ? " met" : ""}`, title: `${ml} ml` });
        b.style.height = `${Math.max(2, Math.round((ml / top) * 100))}%`;
        chart.append(b);
      });
    }
  }

  // ── To-do ──
  const todoText = h("input", { class: "kit-input", type: "text", placeholder: t("Add a task…"), maxlength: "160" }) as HTMLInputElement;
  const todoTime = h("input", { class: "kit-input kit-time", type: "time", title: t("Remind me at") }) as HTMLInputElement;
  const add = () => {
    const due = todoTime.value ? dueFromTime(todoTime.value, Date.now()) : null;
    Kit.addTodo(todoText.value, due);
    todoText.value = "";
    todoTime.value = "";
    actions.holdOpen(false);
  };
  // The island takes the keyboard only while a task is being typed: a reminder
  // opening the page never takes it from the app in front.
  for (const input of [todoText, todoTime]) {
    input.addEventListener("mousedown", () => actions.keyboard(true));
    input.addEventListener("blur", () => window.setTimeout(() => {
      if (document.activeElement !== todoText && document.activeElement !== todoTime) actions.keyboard(false);
    }, 0));
  }
  todoText.addEventListener("input", () => actions.holdOpen(todoText.value.trim() !== ""));
  todoText.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.key === "Enter") add();
  });
  const todoCount = h("span", { class: "kit-count" });
  const clearDone = button(t("Clear done"), "kit-ghost", () => Kit.clearDone());
  const list = h("div", { class: "kit-list" });
  const todoPage = h("div", { class: "kit-page kit-todo" },
    h("div", { class: "kit-row" }, todoText, todoTime, button(t("Add"), "primary", add, ICONS.plus)),
    h("div", { class: "kit-row kit-listhead" }, todoCount, h("div", { class: "grow" }), clearDone),
    list);
  let listKey = "";

  function dueLabel(due: number, now: number): string {
    const d = new Date(due);
    const time = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit", hour12: true });
    const sameDay = new Date(now).toDateString() === d.toDateString();
    return sameDay ? time : `${d.toLocaleDateString([], { weekday: "short" })} ${time}`;
  }

  function syncTodo(now: number) {
    const todos = sortedTodos(Kit.data.todos);
    const done = todos.filter((x) => x.done).length;
    const count = t("{done}/{all} done", { done, all: todos.length });
    if (todoCount.textContent !== count) todoCount.textContent = count;
    clearDone.classList.toggle("off", done === 0);
    const minute = Math.floor(now / 60_000);
    const key = `${minute}|${todos.map((x) => `${x.id}:${x.done ? 1 : 0}:${x.due}:${x.text}`).join(",")}`;
    if (key === listKey) return;
    listKey = key;
    clear(list);
    if (!todos.length) list.append(h("div", { class: "kit-empty", text: t("Nothing to do. Add a task and a time to be reminded.") }));
    for (const x of todos) {
      const check = h("button", { class: `kit-tick${x.done ? " on" : ""}`, title: x.done ? t("Not done") : t("Done"), onclick: () => Kit.toggleTodo(x.id) },
        x.done ? icon(ICONS.check, 10, 2.6) : null);
      const late = !x.done && x.due != null && x.due <= now;
      list.append(h("div", { class: `kit-item${x.done ? " done" : ""}` },
        check,
        h("span", { class: "kit-item-t", text: x.text }),
        x.due != null ? h("span", { class: `kit-due${late ? " late" : ""}` }, icon(KIT_ICONS.bell, 10, 2), h("span", { text: dueLabel(x.due, now) })) : null,
        h("button", { class: "kit-x", title: t("Delete"), onclick: () => Kit.deleteTodo(x.id) }, icon(ICONS.trash, 11, 1.9))));
    }
  }

  // ── Shelf ──
  const shelfStrip = h("div", { class: "kit-strip" });
  shelfStrip.addEventListener("wheel", (e: WheelEvent) => {
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
      shelfStrip.scrollLeft += e.deltaY;
      e.preventDefault();
    }
  }, { passive: false });
  const shelfCount = h("span", { class: "kit-count" });
  const copyAll = button(t("Copy all"), "kit-ghost", () => void Bridge.kitCopyFiles(Kit.data.shelf));
  const clearShelf = button(t("Clear"), "kit-ghost", () => Kit.clearShelf());
  const shelfPage = h("div", { class: "kit-page kit-shelf" },
    h("div", { class: "kit-row kit-listhead" }, shelfCount,
      h("span", { class: "kit-hint", text: t("Drag files onto the Shelf tile to keep them here.") }),
      h("div", { class: "grow" }), copyAll, clearShelf),
    shelfStrip);
  let shelfKey = "";
  const infos = new Map<string, KitFileInfo>();
  const asked = new Set<string>();

  function fileCard(path: string): HTMLElement {
    const info = infos.get(path);
    const name = info?.name ?? path.split(/[\\/]/).pop() ?? path;
    const done = h("div", { class: "kit-done" }, icon(ICONS.check, 14, 2.4), h("span", { text: t("Copied") }));
    const card = h("div", { class: `kit-file${info && !info.exists ? " gone" : ""}`, title: `${path}\n${t("Click to copy, then paste anywhere")}` },
      h("div", { class: "kit-file-ic" }, icon(info?.dir ? ICONS.folder : ICONS.file, 22, 1.5)),
      h("div", { class: "kit-file-n", text: name }),
      h("div", { class: "kit-file-s", text: info ? (info.exists ? (info.dir ? t("Folder") : size(info.size)) : t("Moved or deleted")) : "" }),
      h("div", { class: "kit-file-acts" },
        h("button", { class: "kit-mini", title: t("Open"), onclick: (e: Event) => { e.stopPropagation(); void Bridge.kitOpen(path); } }, icon(ICONS.arrowUpRight, 11, 2)),
        h("button", { class: "kit-mini", title: t("Show in folder"), onclick: (e: Event) => { e.stopPropagation(); void Bridge.kitReveal(path); } }, icon(ICONS.folder, 11, 1.9)),
        h("button", { class: "kit-mini", title: t("Remove from the shelf"), onclick: (e: Event) => { e.stopPropagation(); Kit.unshelve(path); } }, icon(ICONS.xmark, 10, 2))),
      done);
    card.addEventListener("click", () => {
      void Bridge.kitCopyFiles([path]).then((ok) => {
        if (!ok) return;
        card.classList.remove("copied");
        void card.offsetWidth;
        card.classList.add("copied");
      });
    });
    return card;
  }

  function syncShelf() {
    const shelf = Kit.data.shelf;
    const count = String(shelf.length);
    if (shelfCount.textContent !== count) shelfCount.textContent = count;
    copyAll.classList.toggle("off", shelf.length === 0);
    clearShelf.classList.toggle("off", shelf.length === 0);
    const key = shelf.join("|") + "|" + shelf.map((p) => (infos.get(p)?.exists ? 1 : infos.has(p) ? 0 : 2)).join("");
    if (key === shelfKey) return;
    shelfKey = key;
    clear(shelfStrip);
    if (!shelf.length) shelfStrip.append(h("div", { class: "kit-empty", text: t("Your shelf is empty. Drag files onto the island, then onto the Shelf tile.") }));
    for (const p of shelf) shelfStrip.append(fileCard(p));
    // Asked once per opening: an answer that never comes doesn't ask again on every redraw.
    const unknown = shelf.filter((p) => !infos.has(p) && !asked.has(p));
    if (unknown.length) {
      for (const p of unknown) asked.add(p);
      void Bridge.kitFiles(unknown).then((list) => {
        for (const i of list ?? []) infos.set(i.path, i);
        shelfKey = "";
        render();
      }).catch(() => {});
    }
  }

  // ── Prayer (views/prayer.ts) ──
  const prayer = buildPrayerPage(actions);
  const prayerPage = h("div", { class: "kit-page kit-prayer" }, prayer.el);

  const pages: Record<KitPage, HTMLElement> = { focus: focusPage, water: waterPage, todo: todoPage, shelf: shelfPage, prayer: prayerPage };
  const root = h("div", { class: "kit-root" }, bar, focusPage, waterPage, todoPage, shelfPage, prayerPage);
  const el = h("div", { class: "view" }, h("div", { class: "card kit-cardbox" }, root));
  let shownPage: KitPage | null = null;

  function render() {
    const now = Date.now();
    for (const x of tabs) x.b.classList.toggle("on", x.p === Kit.page);
    if (shownPage !== Kit.page) {
      shownPage = Kit.page;
      for (const [p, node] of Object.entries(pages)) node.classList.toggle("on", p === Kit.page);
      // The shelf looks at its files again each time it is opened.
      if (Kit.page === "shelf") {
        infos.clear();
        asked.clear();
        shelfKey = "";
      }
    }
    const b = Kit.banner;
    banner.classList.toggle("on", b != null);
    if (b && bannerText.textContent !== b.message) bannerText.textContent = b.message;
    if (Kit.page === "focus") syncFocus(now);
    else if (Kit.page === "water") syncWater(now);
    else if (Kit.page === "todo") syncTodo(now);
    else if (Kit.page === "prayer") prayer.sync(now);
    else syncShelf();
  }

  Kit.onChange(() => {
    if (State.view === "kit") render();
  });
  // The timer's seconds move while the page is open.
  window.setInterval(() => {
    if (State.view === "kit" && State.mode === "expanded") render();
  }, 500);

  return {
    el,
    sync() {
      if (State.view === "kit") render();
    },
  };
}

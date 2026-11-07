// The Kit's live state: what kit.json holds, the focus timer that runs, and the
// one clock that checks the reminders (a focus phase over, water, a task due)
// whether the page is open or not. The island listens (onAlert) to open the
// page and ring; the page listens (onChange) to redraw.

import { Bridge } from "./bridge";
import {
  addToShelf, defaults, dueTodos, focusLive, IDLE, nextPhase, normalize, pauseFocus, resumeFocus, startFocus,
  tickFocus, waterDue, type FocusPhase, type FocusRun, type KitData, type KitPage, type PrayerPrefs, type Todo,
} from "./kit";
import { FIVE, prayerTimes, type PrayerName } from "./prayer";

export interface KitAlert {
  page: KitPage;
  /** One line for the page's banner: "Time for a break", "Drink some water", the task. */
  message: string;
}

type Labels = { work: string; break: string; long: string };

class KitStore {
  data: KitData = defaults();
  run: FocusRun = IDLE;
  loaded = false;
  /** The page the Kit opens on. */
  page: KitPage = "focus";
  /** The last reminder, shown at the top of its page until it is dismissed. */
  banner: KitAlert | null = null;
  private lastWaterReminder = 0;
  private changeListeners = new Set<() => void>();
  private alertListeners = new Set<(a: KitAlert) => void>();
  private saveTimer: number | null = null;
  private timer: number | null = null;
  private labels: Labels = { work: "Focus", break: "Break", long: "Long break" };
  /** The prayer reminders already given ("2026-11-07|maghrib|pre"), so each rings once. */
  private prayerTold = new Set<string>();
  private prayerListeners = new Set<() => void>();
  private prayerText = {
    soon: (name: PrayerName, min: number) => `${name} in ${min} min`,
    now: (name: PrayerName) => `It's time for ${name}`,
  };
  private texts = {
    workDone: "Round done. Time for a break.",
    breakDone: "Break's over. Back to focus.",
    longDone: "Focus session complete. Well done!",
    water: "Time for some water.",
  };

  async load() {
    try {
      this.data = normalize(await Bridge.kitLoad());
    } catch {
      this.data = defaults();
    }
    this.loaded = true;
    this.changed(false);
    this.timer ??= window.setInterval(() => this.tick(), 1000);
  }

  /** The words the store uses, in the interface's language (set by the page). */
  setTexts(labels: Labels, texts: Partial<typeof this.texts>) {
    this.labels = labels;
    Object.assign(this.texts, texts);
  }

  onChange(fn: () => void): () => void {
    this.changeListeners.add(fn);
    return () => this.changeListeners.delete(fn);
  }

  /** The prayer reminders' words, in the interface's language (set by the page). */
  setPrayerTexts(soon: (name: PrayerName, min: number) => string, now: (name: PrayerName) => string) {
    this.prayerText = { soon, now };
  }

  /** It is a prayer's time and "Pause music at prayer time" is on. */
  onPrayerTime(fn: () => void): () => void {
    this.prayerListeners.add(fn);
    return () => this.prayerListeners.delete(fn);
  }

  onAlert(fn: (a: KitAlert) => void): () => void {
    this.alertListeners.add(fn);
    return () => this.alertListeners.delete(fn);
  }

  private changed(save = true) {
    if (save) this.scheduleSave();
    for (const fn of this.changeListeners) fn();
  }

  private scheduleSave() {
    if (this.saveTimer != null) window.clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => {
      this.saveTimer = null;
      void Bridge.kitSave(this.data).catch(() => {});
    }, 400);
  }

  private alert(a: KitAlert) {
    this.banner = a;
    this.page = a.page;
    for (const fn of this.alertListeners) fn(a);
    this.changed(false);
  }

  /** "Focus 18:42" for the compact island while the timer runs. */
  live(now = Date.now()): string | null {
    return focusLive(this.run, now, this.labels);
  }

  // ── The clock ─────────────────────────────────────────────────────────────

  tick(now = Date.now()) {
    if (!this.loaded) return;
    const f = tickFocus(this.run, this.data.focus, now);
    if (f.ended) {
      this.run = f.run;
      if (f.ended === "work") this.data.focus.log.push({ at: now, min: this.data.focus.workMin });
      this.alert({ page: "focus", message: this.endedText(f.ended) });
      this.changed();
    }
    const due = dueTodos(this.data.todos, now);
    if (due.length) {
      for (const t of due) t.told = true;
      this.alert({ page: "todo", message: due.map((t) => t.text).join(" · ") });
      this.changed();
    }
    if (waterDue(this.data.water, now, this.lastWaterReminder)) {
      this.lastWaterReminder = now;
      this.alert({ page: "water", message: this.texts.water });
    }
    this.tickPrayer(now);
  }

  /**
   * A reminder `remindMin` before each of the five prayers, and one at its
   * time. Each rings once, and only within two minutes of its moment, so
   * starting Coucou late never brings back the day's earlier prayers.
   */
  private tickPrayer(now: number) {
    const p = this.data.prayer;
    if (!p.city) return;
    const times = prayerTimes(now, p.city.lat, p.city.lng, p.method, p.asr);
    const day = new Date(now).toDateString();
    const window = 2 * 60_000;
    for (const name of FIVE) {
      const at = times[name];
      const moments: [string, number, () => string][] = [[`${day}|${name}|at`, at, () => this.prayerText.now(name)]];
      if (p.remindMin > 0) moments.push([`${day}|${name}|pre`, at - p.remindMin * 60_000, () => this.prayerText.soon(name, p.remindMin)]);
      for (const [key, when, text] of moments) {
        if (now < when || now - when > window || this.prayerTold.has(key)) continue;
        this.prayerTold.add(key);
        this.alert({ page: "prayer", message: text() });
        if (key.endsWith("|at") && p.pauseMusic) for (const fn of this.prayerListeners) fn();
      }
    }
    if (this.prayerTold.size > 64) this.prayerTold = new Set([...this.prayerTold].filter((k) => k.startsWith(day)));
  }

  private endedText(phase: FocusPhase): string {
    return phase === "work" ? this.texts.workDone : phase === "long" ? this.texts.longDone : this.texts.breakDone;
  }

  dismissBanner() {
    this.banner = null;
    this.changed(false);
  }

  setPage(p: KitPage) {
    this.page = p;
    this.changed(false);
  }

  // ── Focus ─────────────────────────────────────────────────────────────────

  focusStart() {
    this.run = startFocus(this.data.focus, Date.now());
    this.changed(false);
  }
  focusPause() {
    this.run = pauseFocus(this.run, Date.now());
    this.changed(false);
  }
  focusResume() {
    this.run = resumeFocus(this.run, Date.now());
    this.changed(false);
  }
  focusSkip() {
    this.run = nextPhase(this.run, this.data.focus, Date.now());
    this.changed(false);
  }
  focusStop() {
    this.run = IDLE;
    this.changed(false);
  }
  setFocus(p: Partial<Pick<KitData["focus"], "workMin" | "breakMin" | "longMin" | "rounds">>) {
    Object.assign(this.data.focus, p);
    this.data = normalize(this.data);
    this.changed();
  }

  // ── Water ─────────────────────────────────────────────────────────────────

  drink(ml = this.data.water.sipMl) {
    this.data.water.log.push({ at: Date.now(), ml });
    if (this.banner?.page === "water") this.banner = null;
    this.changed();
  }
  undoDrink() {
    this.data.water.log.pop();
    this.changed();
  }
  setWater(p: Partial<Omit<KitData["water"], "log">>) {
    Object.assign(this.data.water, p);
    this.data = normalize(this.data);
    this.changed();
  }

  // ── To-do ─────────────────────────────────────────────────────────────────

  addTodo(text: string, due: number | null) {
    const t = text.trim();
    if (!t) return;
    const id = this.data.todos.reduce((m, x) => Math.max(m, x.id), 0) + 1;
    this.data.todos.push({ id, text: t, due, done: false, told: false, createdAt: Date.now() });
    this.changed();
  }
  toggleTodo(id: number) {
    const t = this.data.todos.find((x) => x.id === id);
    if (!t) return;
    t.done = !t.done;
    this.changed();
  }
  updateTodo(id: number, p: Partial<Pick<Todo, "text" | "due">>) {
    const t = this.data.todos.find((x) => x.id === id);
    if (!t) return;
    if (p.text != null && p.text.trim()) t.text = p.text.trim();
    if (p.due !== undefined) {
      t.due = p.due;
      t.told = false;
    }
    this.changed();
  }
  deleteTodo(id: number) {
    this.data.todos = this.data.todos.filter((x) => x.id !== id);
    this.changed();
  }
  clearDone() {
    this.data.todos = this.data.todos.filter((x) => !x.done);
    this.changed();
  }

  // ── Prayer ────────────────────────────────────────────────────────────────

  setPrayer(p: Partial<PrayerPrefs>) {
    this.data.prayer = { ...this.data.prayer, ...p };
    this.data = normalize(this.data);
    this.changed();
  }

  // ── Shelf ─────────────────────────────────────────────────────────────────

  shelve(paths: string[]) {
    this.data.shelf = addToShelf(this.data.shelf, paths);
    this.page = "shelf";
    this.changed();
  }
  unshelve(path: string) {
    this.data.shelf = this.data.shelf.filter((p) => p !== path);
    this.changed();
  }
  clearShelf() {
    this.data.shelf = [];
    this.changed();
  }
}

export const Kit = new KitStore();

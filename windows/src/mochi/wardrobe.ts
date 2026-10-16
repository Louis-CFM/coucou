// Mochi's wardrobe — the pure logic, port of NotchBuddy/Sources/CoucouKit/MochiWardrobe.swift.
// What Mochi wears is picked in the wardrobe view (right-click on Mochi, the
// tray menu, or Settings). Each Mochi has its own look (`mochiLooks`, which
// Rust keeps in wardrobe-looks.json), unless `wardrobeMode` is "all": then
// every Mochi wears `mochiOutfit` and `mochiShape`. The drawing lives in
// ./outfits.ts.

import { N_, labels, t } from "../i18n/i18n";

/** Every outfit, plus "auto" (dress for the season) and "none". Order of the wardrobe. */
export const OUTFIT_SELECTIONS = [
  "auto", "none", "partyHat", "beanie", "crown", "sunglasses", "roundGlasses",
  "bow", "scarf", "witchHat", "pumpkin", "santaHat", "bunnyEars",
] as const;

/** What can be stored in the preferences. The raw values are the Mac's, keep them stable. */
export type OutfitSelection = (typeof OUTFIT_SELECTIONS)[number];

/** What Mochi actually wears: a selection with "auto" resolved. */
export type Outfit = Exclude<OutfitSelection, "auto">;

export const DEFAULT_OUTFIT: OutfitSelection = "auto";

// ── User-visible strings ──────────────────────────────────────────────────────

/** The English names, the keys of their translations (src/i18n). */
export const OUTFIT_KEYS: Record<OutfitSelection, string> = {
  auto: N_("Auto (seasons)"),
  none: N_("None"),
  partyHat: N_("Party hat"),
  beanie: N_("Beanie"),
  crown: N_("Crown"),
  sunglasses: N_("Sunglasses"),
  roundGlasses: N_("Round glasses"),
  bow: N_("Bow"),
  scarf: N_("Scarf"),
  witchHat: N_("Witch hat"),
  pumpkin: N_("Pumpkin"),
  santaHat: N_("Santa hat"),
  bunnyEars: N_("Bunny ears"),
};

/** In the current language: every read goes through `t()`. */
export const OUTFIT_LABELS: Record<OutfitSelection, string> = labels(OUTFIT_KEYS);

export const WARDROBE_STRINGS = {
  get title() { return t("Wardrobe"); },
  get autoBadge() { return t("AUTO"); },
  autoNow: (current: string) => t("Auto · {outfit}", { outfit: current }),
  autoHover: (current: string) => t("Auto · follows the seasons (now: {outfit})", { outfit: current }),
};

// ── Body shapes (their geometry is in ./shapes.ts) ────────────────────────────

/** The shapes' English names, the keys of their translations. */
export const SHAPE_KEYS: Record<string, string> = {
  mochi: N_("Mochi"),
  daifuku: N_("Daifuku"),
  bean: N_("Bean"),
  tofu: N_("Tofu"),
  onigiri: N_("Onigiri"),
};

// ── Logic ─────────────────────────────────────────────────────────────────────

const SELECTION_SET: ReadonlySet<string> = new Set(OUTFIT_SELECTIONS);

/**
 * A stored preference → a selection. Anything unknown (a value from a newer or
 * older build, such as the Mac's removed "topHat", or garbage) means "auto",
 * exactly like `Outfit.stored` on macOS.
 */
export function parseOutfit(raw: unknown): OutfitSelection {
  return typeof raw === "string" && SELECTION_SET.has(raw) ? (raw as OutfitSelection) : DEFAULT_OUTFIT;
}

/** Easter Sunday of `year` (Meeus/Jones/Butcher), as [month 1–12, day]. */
export function easterDate(year: number): [number, number] {
  const a = year % 19;
  const b = Math.floor(year / 100);
  const c = year % 100;
  const d = Math.floor(b / 4);
  const e = b % 4;
  const f = Math.floor((b + 8) / 25);
  const g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4);
  const k = c % 4;
  const l = (32 + 2 * e + 2 * i - h - k) % 7;
  const m = Math.floor((a + 11 * h + 22 * l) / 451);
  const month = Math.floor((h + l - 7 * m + 114) / 31);
  const day = ((h + l - 7 * m + 114) % 31) + 1;
  return [month, day];
}

const DAY_MS = 86_400_000;

/**
 * The seasonal outfit for `date`, read in the user's local calendar.
 * Priority: party hat > Santa hat > witch hat > bunny ears > sunglasses > none.
 */
export function seasonalOutfit(date: Date): Outfit {
  const day = date.getDate();
  const month = date.getMonth() + 1;
  const year = date.getFullYear();

  // Dec 31 – Jan 2
  if ((month === 12 && day === 31) || (month === 1 && day <= 2)) return "partyHat";
  // Dec 1–26
  if (month === 12 && day <= 26) return "santaHat";
  // Oct 1 – Nov 1
  if (month === 10 || (month === 11 && day === 1)) return "witchHat";
  // Two days before Easter to the day after. Calendar days counted in UTC so a
  // daylight-saving change in between can't shift the count.
  const [em, ed] = easterDate(year);
  const delta = Math.round((Date.UTC(year, month - 1, day) - Date.UTC(year, em - 1, ed)) / DAY_MS);
  if (delta >= -2 && delta <= 1) return "bunnyEars";
  // Jun 21 – Aug 31
  if ((month === 6 && day >= 21) || month === 7 || month === 8) return "sunglasses";
  return "none";
}

/** "auto" → the season's outfit; anything else is worn as chosen. */
export function resolveOutfit(selection: OutfitSelection, date: Date): Outfit {
  return selection === "auto" ? seasonalOutfit(date) : selection;
}

/**
 * The grey text at the right of the wardrobe header: the hovered outfit,
 * otherwise the current choice — WardrobeView.headerRight on macOS.
 */
export function wardrobeHeader(
  hovered: OutfitSelection | null,
  selection: OutfitSelection,
  date: Date,
): string {
  const season = OUTFIT_LABELS[seasonalOutfit(date)];
  if (hovered) return hovered === "auto" ? WARDROBE_STRINGS.autoHover(season) : OUTFIT_LABELS[hovered];
  return selection === "auto" ? WARDROBE_STRINGS.autoNow(season) : OUTFIT_LABELS[selection];
}

// ── Whose look ───────────────────────────────────────────────────────────────

/** The main Mochi's key in `mochiLooks`; a coloured Mochi's is its pill id. */
export const MAIN_MOCHI = "main";

/** "perMochi": each Mochi wears its own look. "all": they all wear the same. */
export type WardrobeMode = "perMochi" | "all";

/** One Mochi's look as stored: raw values, read through lookOf. */
export interface MochiLook {
  outfit: string;
  shape: string;
}

/** The settings the wardrobe reads and writes. */
export interface LookSettings {
  wardrobeMode?: string;
  mochiOutfit: string;
  mochiShape: string;
  mochiLooks?: Record<string, MochiLook>;
}

/** Anything but "all" (missing, from an older build) is one look per Mochi. */
export function parseWardrobeMode(raw: unknown): WardrobeMode {
  return raw === "all" ? "all" : "perMochi";
}

/**
 * Which Mochi a pill shows: a coloured Mochi is its pill's, the main pill and
 * any session pill show the main Mochi (the island draws them in his colours).
 */
export function mochiKey(task: { id: string; isIntegration: boolean } | null | undefined, mainPillId: string): string {
  return task?.isIntegration && task.id !== mainPillId ? task.id : MAIN_MOCHI;
}

/**
 * What the Mochi `key` wears: in "all" mode the shared look, else its own. A
 * Mochi never dressed yet dresses for the seasons, in the classic body.
 */
export function lookOf(s: LookSettings, key: string): { outfit: OutfitSelection; shape: string } {
  const raw = parseWardrobeMode(s.wardrobeMode) === "all"
    ? { outfit: s.mochiOutfit, shape: s.mochiShape }
    : s.mochiLooks?.[key];
  return { outfit: parseOutfit(raw?.outfit), shape: typeof raw?.shape === "string" ? raw.shape : "" };
}

/**
 * A wardrobe pick for the Mochi `key`, kept where the current mode reads it.
 * The other mode's looks are left as they are, so switching back finds them.
 */
export function setLook(s: LookSettings, key: string, change: Partial<MochiLook>): void {
  if (parseWardrobeMode(s.wardrobeMode) === "all") {
    if (change.outfit != null) s.mochiOutfit = change.outfit;
    if (change.shape != null) s.mochiShape = change.shape;
    return;
  }
  s.mochiLooks = { ...s.mochiLooks, [key]: { ...lookOf(s, key), ...change } };
}

/** Same as resolveOutfit, remembered for the day — it is asked every frame. */
export class SeasonCache {
  private key = "";
  private value: Outfit = "none";

  get(selection: OutfitSelection, date = new Date()): Outfit {
    if (selection !== "auto") return selection;
    const key = `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
    if (key !== this.key) {
      this.key = key;
      this.value = seasonalOutfit(date);
    }
    return this.value;
  }
}

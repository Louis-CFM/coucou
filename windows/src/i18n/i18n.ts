// Interface language — the same languages as the Mac.
//
// Strings are looked up by their English text, like the Mac's catalog:
// `t("Allow")`, `t("Uploading {name}", { name })`. Two tables, both keyed by
// the English text:
// - strings.json, generated from the Mac's Localizable.xcstrings by
//   scripts/gen-strings.mjs (never edited by hand);
// - extra.json, the strings only Windows and Linux have, written by hand.
// A string missing from both, or from one language, shows in English.
//
// The Rust side (src-tauri/src/i18n.rs) embeds the same two files and looks up
// the same way, for the tray menu, notifications and the errors it returns.
//
// Changing the language never reloads a window: `setLanguage` tells whoever
// listens (`onLanguageChange`), views/dom.ts relabels the text it was given
// as `tl(…)`, and the views redraw the rest on their next sync.

import MAC from "./strings.json";
import EXTRA from "./extra.json";

export const LANGUAGE_CODES = ["en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt-BR", "ru", "id", "tr"] as const;
export type Language = (typeof LANGUAGE_CODES)[number];

/** The picker's entries, each in its own language, in the Mac's order. */
export const LANGUAGES: readonly { code: Language; name: string }[] = [
  { code: "en", name: "English" },
  { code: "zh-Hans", name: "简体中文" },
  { code: "hi", name: "हिन्दी" },
  { code: "es", name: "Español" },
  { code: "ar", name: "العربية" },
  { code: "fr", name: "Français" },
  { code: "bn", name: "বাংলা" },
  { code: "pt-BR", name: "Português (Brasil)" },
  { code: "ru", name: "Русский" },
  { code: "id", name: "Bahasa Indonesia" },
  { code: "tr", name: "Türkçe" },
];

export type Vars = Record<string, string | number>;
type Plural = Partial<Record<Intl.LDMLPluralRule, string>>;
type Entry = Partial<Record<Language, string | Plural>>;
type Table = Record<string, Entry>;

/** extra.json wins over the Mac's table where both have a string. */
const TABLE: Table = {
  ...((MAC as { strings: Table }).strings),
  ...((EXTRA as { strings: Table }).strings),
};

let current: Language = "en";
const listeners = new Set<(lang: Language) => void>();

export function isLanguage(code: unknown): code is Language {
  return typeof code === "string" && (LANGUAGE_CODES as readonly string[]).includes(code);
}

/**
 * The language to show: the one picked in Settings when it is one of ours,
 * else the first of the system's languages we have ("pt" and "pt-PT" read as
 * Brazilian Portuguese, "zh-CN", "zh-SG" and "zh" as Simplified Chinese),
 * else English.
 */
export function resolveLanguage(picked: string | undefined | null, system: readonly string[] = []): Language {
  if (isLanguage(picked)) return picked;
  for (const raw of system) {
    const tag = String(raw ?? "").replace(/_/g, "-").toLowerCase();
    if (!tag) continue;
    const base = tag.split("-")[0];
    if (base === "zh") {
      // Traditional Chinese is not one of ours: English rather than the wrong script.
      if (/^zh-(hant|tw|hk|mo)\b/.test(tag)) continue;
      return "zh-Hans";
    }
    if (base === "pt") return "pt-BR";
    const exact = LANGUAGE_CODES.find((c) => c.toLowerCase() === base);
    if (exact) return exact;
  }
  return "en";
}

/** The system's languages, as the webview knows them. */
export function systemLanguages(): string[] {
  if (typeof navigator === "undefined") return [];
  const list = navigator.languages?.length ? [...navigator.languages] : [];
  if (navigator.language && !list.includes(navigator.language)) list.push(navigator.language);
  return list;
}

export function language(): Language {
  return current;
}

/** Arabic reads right to left. */
export function isRtl(lang: Language = current): boolean {
  return lang === "ar";
}

/** Switches the language. Returns true when it changed (listeners were told). */
export function setLanguage(lang: Language): boolean {
  if (!isLanguage(lang) || lang === current) return false;
  current = lang;
  applyDocumentLanguage();
  for (const listener of [...listeners]) listener(lang);
  return true;
}

/** Called after every language change; returns the unsubscribe. */
export function onLanguageChange(listener: (lang: Language) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/**
 * <html lang> follows the language, so the webview picks fitting fonts, and
 * <html data-dir> says which way it reads: the island's CSS turns its text
 * containers right to left with it, leaving Mochi, the pills and the header
 * where they are. (The settings window sets `dir` on the whole page.)
 */
export function applyDocumentLanguage() {
  if (typeof document === "undefined" || !document.documentElement) return;
  const root = document.documentElement;
  root.lang = current;
  if (root.dataset) root.dataset.dir = isRtl() ? "rtl" : "ltr";
}

function interpolate(text: string, vars?: Vars): string {
  if (!vars) return text;
  return text.replace(/\{(\w+)\}/g, (m, name: string) => (name in vars ? String(vars[name]) : m));
}

function pluralRule(lang: Language, count: number): Intl.LDMLPluralRule {
  try {
    return new Intl.PluralRules(lang).select(count);
  } catch {
    return count === 1 ? "one" : "other";
  }
}

function pickPlural(forms: Plural, lang: Language, count: number): string | undefined {
  return forms[pluralRule(lang, count)] ?? forms.other ?? Object.values(forms)[0];
}

/** The raw translation of `key` in `lang`, or undefined. */
export function lookup(key: string, lang: Language = current): string | Plural | undefined {
  if (lang === "en") return undefined;
  return TABLE[key]?.[lang];
}

/**
 * `key` (English text) in the current language, its `{placeholders}` filled
 * from `vars`. Falls back to the English text.
 */
export function t(key: string, vars?: Vars): string {
  const found = lookup(key);
  let text: string;
  if (typeof found === "string") text = found;
  else if (found) text = pickPlural(found, current, Number(vars?.count ?? 0)) ?? key;
  else text = key;
  return interpolate(text, vars);
}

/**
 * A count with its words: `tn("{count} file", "{count} files", n)`. Languages
 * with more forms (Russian, Arabic…) pick theirs from the entry keyed by the
 * English plural; `{count}` is filled in.
 */
export function tn(one: string, other: string, count: number, vars?: Vars): string {
  const all = { ...vars, count };
  const found = lookup(other);
  if (found && typeof found !== "string") {
    const text = pickPlural(found, current, count);
    if (text) return interpolate(text, all);
  }
  if (typeof found === "string") return interpolate(found, all);
  // English, or a language without this string: the English forms.
  const englishForms = TABLE[other]?.en;
  if (englishForms && typeof englishForms !== "string") {
    const text = pickPlural(englishForms, "en", count);
    if (text) return interpolate(text, all);
  }
  return interpolate(count === 1 ? one : other, all);
}

/**
 * Marks a literal as a key without translating it, for tables built at load
 * time (pill categories, outfit names…): the code translates it with `t()`
 * where it is shown. The i18n test finds the keys through it.
 */
export function N_<T extends string>(key: T): T {
  return key;
}

/**
 * A table of labels whose every read is translated: `labels({ a: N_("Bow") }).a`
 * is "Bow" in English, "Nœud" in French. For tables other modules index into.
 */
export function labels<K extends string>(keys: Record<K, string>): Record<K, string> {
  const out = {} as Record<K, string>;
  for (const k of Object.keys(keys) as K[]) {
    Object.defineProperty(out, k, { enumerable: true, get: () => t(keys[k]) });
  }
  return out;
}

/**
 * A string that follows the language by itself once it is on screen. Given to
 * `h()` (views/dom.ts) as a text, a title, a placeholder or a child, it is
 * redrawn in place when the language changes.
 */
export class Msg {
  readonly key: string;
  readonly vars?: Vars;
  constructor(key: string, vars?: Vars) {
    this.key = key;
    this.vars = vars;
  }
  toString(): string {
    return t(this.key, this.vars);
  }
}

/** `t()` for text built once: see `Msg`. */
export function tl(key: string, vars?: Vars): Msg {
  return new Msg(key, vars);
}

// ── Dates ─────────────────────────────────────────────────────────────────────
// English keeps the Mac's fixed abbreviations; the other languages ask Intl.

const EN_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const EN_WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function intl(options: Intl.DateTimeFormatOptions, date: Date): string | null {
  try {
    return new Intl.DateTimeFormat(current, { ...options, timeZone: "UTC" }).format(date);
  } catch {
    return null;
  }
}

/** "Oct" for 9 (months from 0). */
export function monthShort(month: number): string {
  if (current === "en") return EN_MONTHS[month] ?? "";
  return intl({ month: "short" }, new Date(Date.UTC(2024, month, 15))) ?? EN_MONTHS[month] ?? "";
}

/** "Mon" for 1 (Sunday is 0). */
export function weekdayShort(day: number): string {
  if (current === "en") return EN_WEEKDAYS[day] ?? "";
  // 7 January 2024 was a Sunday.
  return intl({ weekday: "short" }, new Date(Date.UTC(2024, 0, 7 + day))) ?? EN_WEEKDAYS[day] ?? "";
}

/** "Oct 9" (months from 0), in the language's own order. */
export function dayMonth(month: number, day: number): string {
  if (current === "en") return `${EN_MONTHS[month] ?? ""} ${day}`;
  return intl({ month: "short", day: "numeric" }, new Date(Date.UTC(2024, month, day))) ?? `${EN_MONTHS[month] ?? ""} ${day}`;
}

/** Every key of both tables, for the tests. */
export function allKeys(): string[] {
  return Object.keys(TABLE);
}

/** True when `key` has a translation in every language but English. */
export function isComplete(key: string): boolean {
  const entry = TABLE[key];
  return !!entry && LANGUAGE_CODES.every((l) => l === "en" || entry[l] !== undefined);
}

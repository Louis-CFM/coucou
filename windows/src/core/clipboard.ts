// The notch's Clipboard (src-tauri/src/clipboard.rs keeps the items, in memory
// only): what each item is, which filter shows it, and the order of the cards.

/** One item as Rust sends it (clipboard.rs Item). */
export interface ClipItem {
  id: number;
  kind: "text" | "image" | "files";
  /** The text, cut for the card; the files' paths, one per line. */
  text: string;
  /** The whole text's length. */
  chars: number;
  files: string[];
  /** The app it was copied from, when Coucou could tell. */
  app: string | null;
  /** Epoch ms. */
  at: number;
  pinned: boolean;
}

/** What a card shows it as: a text item can be a link, a colour or code. */
export type ClipLook = "text" | "link" | "color" | "code" | "image" | "files";

export type ClipFilter = "all" | "text" | "links" | "images" | "files";

const URL_RE = /^(https?:\/\/|www\.)\S+$/i;
const COLOR_RE = /^(#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})|(?:rgb|rgba|hsl|hsla)\([^)]{3,40}\))$/i;
const CODE_RE = /[{};]\s*$|=>|^\s*(?:def|function|const|let|var|import|export|class|if|for|return|SELECT|fn|pub|#include)\b|<\/?[a-z][\w-]*[^>]*>/im;

export function look(item: ClipItem): ClipLook {
  if (item.kind !== "text") return item.kind;
  const t = item.text.trim();
  if (!t.includes("\n") && URL_RE.test(t)) return "link";
  if (COLOR_RE.test(t)) return "color";
  const lines = t.split("\n");
  if (lines.length >= 2 && (CODE_RE.test(t) || lines.filter((l) => /^(\s{2,}|\t)/.test(l)).length >= 2)) return "code";
  return "text";
}

export function matches(item: ClipItem, filter: ClipFilter): boolean {
  const l = look(item);
  switch (filter) {
    case "all":
      return true;
    case "text":
      return l === "text" || l === "code" || l === "color";
    case "links":
      return l === "link";
    case "images":
      return l === "image";
    case "files":
      return l === "files";
  }
}

/** Pinned first, then the newest. */
export function ordered(items: ClipItem[], filter: ClipFilter): ClipItem[] {
  return items
    .filter((i) => matches(i, filter))
    .sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.at - a.at);
}

/** A link's host for the card's title: "github.com". */
export function linkHost(text: string): string {
  const t = text.trim();
  try {
    return new URL(/^www\./i.test(t) ? `https://${t}` : t).host.replace(/^www\./, "");
  } catch {
    return t;
  }
}

/** The last part of a path, Windows or not: "report.pdf". */
export function fileName(path: string): string {
  const parts = path.split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] ?? path;
}

/** "now", "5 min. ago", "2 hr. ago"… in the language shown (no string of our own). */
export function ago(at: number, now: number, lang: string): string {
  const s = Math.max(0, Math.round((now - at) / 1000));
  const rtf = new Intl.RelativeTimeFormat(lang, { numeric: "auto", style: "narrow" });
  if (s < 45) return rtf.format(0, "second");
  if (s < 3600) return rtf.format(-Math.round(s / 60), "minute");
  if (s < 86_400) return rtf.format(-Math.round(s / 3600), "hour");
  return rtf.format(-Math.round(s / 86_400), "day");
}

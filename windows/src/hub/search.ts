// The search box at the top of the Coucou window's sidebar: what you type finds
// the page or the setting, in the language you read it in (or in English), and
// shell.ts opens the page and underlines the setting.
//
// The settings are listed here by hand, by the English text of their label
// (N_("…"): the i18n test checks each one is translated). The page draws the
// label through t() as it always did, so the text shown now is the text to look
// for on the page. A setting that is not on the page when it opens (the phone's
// options appear once the link is on) still opens its page, just not underlined.

import { N_, t } from "../i18n/i18n";
import type { PageId } from "./shell";

interface Entry {
  page: PageId;
  /** The label's English text, as it is drawn on the page. */
  key: string;
}

export const SETTINGS: readonly Entry[] = [
  // Flow
  { page: "dictation", key: N_("Turn on dictation") },
  { page: "dictation", key: N_("Parakeet, on your computer") },
  { page: "dictation", key: N_("History") },
  { page: "styles", key: N_("Style per app") },
  { page: "styles", key: N_("Other apps") },
  { page: "styles", key: N_("Clean up with Claude") },
  { page: "flowsettings", key: N_("Keys") },
  { page: "flowsettings", key: N_("Hold a key to dictate anywhere") },
  { page: "flowsettings", key: N_("Hold to dictate") },
  { page: "flowsettings", key: N_("Where the pill is") },
  { page: "flowsettings", key: N_("Hands-free") },
  { page: "flowsettings", key: N_("Paste the last dictation again") },
  { page: "flowsettings", key: N_("Cancel a dictation") },
  { page: "flowsettings", key: N_("Microphone") },
  { page: "flowsettings", key: N_("Recognition") },
  { page: "flowsettings", key: N_("Parakeet, on your computer") },
  { page: "flowsettings", key: N_("Summaries") },
  { page: "flowsettings", key: N_("Open this window when you open Coucou") },
  { page: "flowsettings", key: N_("Privacy") },
  { page: "flowsettings", key: N_("Keep the history") },
  // Notch
  { page: "general", key: N_("Sound") },
  { page: "general", key: N_("Open on hover") },
  { page: "general", key: N_("Show clock in the island") },
  { page: "general", key: N_("Auto-close") },
  { page: "general", key: N_("Island lives on") },
  { page: "general", key: N_("Launch at startup") },
  { page: "general", key: N_("Weekly recap") },
  { page: "general", key: N_("Updates") },
  { page: "general", key: N_("Language") },
  { page: "pills", key: N_("Main tool") },
  { page: "agents", key: N_("Plan usage") },
  { page: "agents", key: N_("Show in notch") },
  { page: "agents", key: N_("Show Codex plan in the notch") },
  { page: "chat", key: N_("API key") },
  { page: "chat", key: N_("Model") },
  { page: "chat", key: N_("Chat providers") },
  { page: "chat", key: N_("Local models") },
  { page: "voice", key: N_("Listening") },
  { page: "voice", key: N_("Answers") },
  { page: "voice", key: N_("Coucou answers out loud") },
  { page: "voice", key: N_("Voice") },
  { page: "voice", key: N_("ElevenLabs key") },
  { page: "voice", key: N_("Privacy") },
  { page: "phone", key: N_("Phone link") },
  { page: "phone", key: N_("Away from home Wi-Fi") },
  { page: "phone", key: N_("Relay address") },
  { page: "phone", key: N_("Relay access key") },
  { page: "phone", key: N_("Show session details on the phone") },
  { page: "phone", key: N_("Let the phone answer Claude Code's questions") },
  { page: "phone", key: N_("Show these services on the phone") },
  { page: "phone", key: N_("Show my plan usage on the phone") },
  { page: "phone", key: N_("Show the files an agent changed on the phone") },
  { page: "phone", key: N_("Let the phone chat with my AI providers") },
  { page: "shortcuts", key: N_("From anywhere") },
  { page: "shortcuts", key: N_("In the open island") },
];

/** A page of the window, as the sidebar shows it now. */
export interface PageInfo {
  id: PageId;
  title: string;
  /** Where it is: "Flow" or "Notch". */
  group: string;
}

export interface Hit {
  page: PageId;
  /** What the result says, and the text to underline on the page (settings only). */
  text: string;
  /** "Notch · General". */
  where: string;
  /** False for a page itself, which just opens. */
  setting: boolean;
}

/** Lower case, without the accents: "Réglages" and "reglages" are the same word. */
export function normalize(text: string): string {
  return text.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
}

/** 0 when `name` starts with the query, 1 at the start of a word, 2 anywhere; null when it is not there. */
function rank(query: string, tokens: string[], names: string[]): number | null {
  const [shown] = names;
  if (shown.startsWith(query)) return 0;
  if (` ${shown}`.includes(` ${query}`)) return 1;
  const all = names.join(" ");
  return tokens.every((word) => all.includes(word)) ? 2 : null;
}

const MAX_HITS = 20;

/**
 * The pages and settings that match `query`, the best first. Each word of the
 * query has to be in the name, in the current language or in English.
 */
export function searchSettings(query: string, pages: readonly PageInfo[]): Hit[] {
  const tokens = normalize(query).split(/\s+/).filter(Boolean);
  if (!tokens.length) return [];
  const wanted = tokens.join(" ");
  const where = new Map(pages.map((p) => [p.id, p]));
  const found: { hit: Hit; rank: number }[] = [];

  for (const page of pages) {
    const r = rank(wanted, tokens, [normalize(page.title)]);
    if (r !== null) found.push({ rank: r, hit: { page: page.id, text: page.title, where: page.group, setting: false } });
  }
  for (const entry of SETTINGS) {
    const page = where.get(entry.page);
    if (!page) continue;
    const text = t(entry.key);
    const r = rank(wanted, tokens, [normalize(text), normalize(entry.key)]);
    if (r !== null) found.push({ rank: r, hit: { page: entry.page, text, where: `${page.group} · ${page.title}`, setting: true } });
  }
  // A stable sort: at the same rank, the pages and then the settings keep their order.
  return found.sort((a, b) => a.rank - b.rank).slice(0, MAX_HITS).map((f) => f.hit);
}

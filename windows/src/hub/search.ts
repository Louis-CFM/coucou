// Settings search in the Coucou window: matches every setting of Flow,
// Notch and Mail in the app's language, whatever the accents and case.
// Port of SettingsSearch.swift and SettingsSearchMatch.swift.

import { t } from "../i18n/i18n";
import type { PageId } from "./shell";

export interface SettingsSearchEntry {
  /** The box's anchor, unique. */
  id: string;
  page: PageId;
  /** The box's title (catalog key, or a name that is never translated). */
  title: string;
  /** The labels inside the box (catalog keys). */
  terms: string[];
  /** A sidebar page rather than a box to scroll to. */
  isPage?: boolean;
}

export interface SettingsSearchHit {
  entry: SettingsSearchEntry;
  label?: string;
  id: string;
}

export type MatchResult =
  | { kind: "box" }
  | { kind: "label"; label: string };

/**
 * Normalizes a string for searching: case-insensitive, diacritic/accent-insensitive,
 * trimmed of leading/trailing whitespace.
 */
export function normalize(s: string): string {
  return s
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .trim();
}

/**
 * The words of a query, normalized.
 */
export function words(query: string): string[] {
  return query
    .split(/\s+/)
    .map(normalize)
    .filter((w) => w.length > 0);
}

/**
 * Matches a list of query words against a box's title, page and inner labels.
 * Returns null when the box doesn't have every word.
 */
export function match(
  wordList: string[],
  title: string,
  page: string,
  labels: string[]
): MatchResult | null {
  if (wordList.length === 0) return null;
  const head = normalize(title + " " + page);
  const texts = labels.map(normalize);
  const all = [head, ...texts].join(" ");
  if (!wordList.every((w) => all.includes(w))) return null;
  if (wordList.every((w) => head.includes(w))) return { kind: "box" };

  // The label with the most of the words, the first one when tied.
  let bestIndex = -1;
  let bestCount = 0;
  for (let i = 0; i < texts.length; i++) {
    const text = texts[i];
    const count = wordList.filter((w) => text.includes(w)).length;
    if (count > 0 && count > bestCount) {
      bestIndex = i;
      bestCount = count;
    }
  }

  if (bestIndex < 0) return { kind: "box" };
  return { kind: "label", label: labels[bestIndex] };
}

export const SETTINGS_ENTRIES: SettingsSearchEntry[] = [
  // Flow
  { id: "flow.history", page: "dictation", title: "History", terms: ["Dictation"] },
  { id: "flow.notes", page: "notes", title: "Notetaker", terms: ["Live", "Key points"] },
  { id: "flow.insights", page: "insights", title: "Statistics", terms: [] },
  { id: "flow.dictionary", page: "dictionary", title: "Dictionary", terms: ["Replacements"] },
  { id: "flow.snippets", page: "snippets", title: "Snippets", terms: [] },
  { id: "flow.styles", page: "styles", title: "Styles", terms: ["Clean up with Claude", "Other apps", "Style per app"] },
  {
    id: "flow.keys",
    page: "flowsettings",
    title: "Keys",
    terms: ["Hold a key to dictate anywhere", "Hold the key", "Where the pill is", "Hands-free", "Paste the last dictation again", "Cancel a dictation"],
  },
  { id: "flow.ai", page: "flowsettings", title: "Prompt and translation", terms: ["Prompt mode", "Translate into"] },
  { id: "flow.permission", page: "flowsettings", title: "Permission", terms: ["Open Accessibility settings"] },
  { id: "flow.recognition", page: "flowsettings", title: "Recognition", terms: ["Dictation language"] },
  { id: "flow.summary", page: "flowsettings", title: "Notetaker", terms: ["Summaries"] },
  { id: "flow.app", page: "flowsettings", title: "App", terms: ["Show Coucou in the Dock", "Open this window when you open Coucou"] },
  { id: "flow.privacy", page: "flowsettings", title: "Privacy", terms: ["Keep the history"] },

  // Notch → General
  { id: "general.demo", page: "general", title: "Demo", terms: [] },
  { id: "general.sound", page: "general", title: "Sound", terms: ["Enable sounds", "Volume", "Open sounds folder", "Reload sounds"] },
  { id: "general.behavior", page: "general", title: "Behavior", terms: ["Open on hover", "Close after", "Hide after", "Open for every pill’s alerts"] },
  { id: "general.display", page: "general", title: "Display", terms: ["Show Mochi on", "The main screen", "The screen under the mouse", "A specific screen"] },
  { id: "general.vitals", page: "general", title: "Mochi and your computer", terms: ["Mochi reacts to your Mac"] },
  { id: "general.hotkey", page: "general", title: "Hotkey", terms: ["Show island with shortcut", "Shortcut"] },
  { id: "general.startup", page: "general", title: "Startup", terms: ["Launch at startup"] },
  { id: "general.update", page: "general", title: "Updates", terms: [] },
  { id: "general.recap", page: "general", title: "Weekly recap", terms: ["Keep a history of my coding sessions", "Hide project names in shared images", "Clear history"] },
  { id: "general.language", page: "general", title: "Language", terms: ["Restart Coucou"] },

  // Notch → Pills, Agents, Chat, Integrations, Phone, Voice, Shortcuts
  { id: "pills.main", page: "pills", title: "Main", terms: ["Active pills"] },
  { id: "agents.claude", page: "agents", title: "Claude Code hooks", terms: ["Answer questions and permissions from terminal sessions in the notch"] },
  { id: "agents.claude-desktop", page: "agents", title: "Claude Desktop chats (experimental)", terms: [] },
  { id: "agents.gemini", page: "agents", title: "Gemini CLI hooks", terms: [] },
  { id: "agents.antigravity", page: "agents", title: "Antigravity hooks", terms: [] },
  { id: "agents.codex", page: "agents", title: "Codex hooks", terms: [] },
  { id: "agents.copilot", page: "agents", title: "GitHub Copilot CLI hooks", terms: [] },
  { id: "agents.muse", page: "agents", title: "Muse Code hooks", terms: [] },
  { id: "agents.opencode", page: "agents", title: "OpenCode plugin", terms: [] },
  { id: "agents.amp", page: "agents", title: "Amp plugin", terms: [] },
  { id: "agents.hermes", page: "agents", title: "Hermes Agent", terms: ["Show approval requests in the notch"] },
  { id: "agents.plan", page: "agents", title: "Plan usage", terms: ["Show in notch", "Show Codex plan in the notch"] },
  { id: "chat.subscriptions", page: "chat", title: "Your AI subscriptions", terms: ["Use my subscription"] },
  { id: "chat.anthropic", page: "chat", title: "Anthropic API", terms: ["Model", "Anthropic", "Claude"] },
  { id: "chat.others", page: "chat", title: "Chat — other providers", terms: ["Google AI", "OpenAI", "DeepSeek", "Gemini"] },
  { id: "chat.local", page: "chat", title: "Local models", terms: ["Ollama", "LM Studio"] },
  {
    id: "integrations.all",
    page: "integrations",
    title: "Integrations",
    terms: [
      "Stripe", "GitHub", "Vercel", "n8n", "Notion", "Resend", "Cal.com", "WhatsApp", "Spotify", "Crypto",
      "Linear", "X", "YouTube", "Figma", "OpenWeather", "Railway", "Supabase", "Hugging Face", "Sentry", "PostHog", "Twilio",
    ],
  },
  { id: "phone.android", page: "phone", title: "Android phone", terms: ["Phone link", "Show the sessions on the phone", "Allow approvals from the phone"] },
  { id: "voice.wake", page: "voice", title: "«\u202FOK Coucou\u202F» — voice wake word", terms: ["Enable voice command", "Request permissions"] },
  { id: "voice.language", page: "voice", title: "Language", terms: ["You speak", "Coucou answers in"] },
  { id: "voice.tts", page: "voice", title: "Voice", terms: ["Voice type", "Test the voice"] },
  { id: "voice.history", page: "voice", title: "Recently heard phrases", terms: [] },
  { id: "shortcuts.global", page: "shortcuts", title: "Global shortcuts — active from any app", terms: [] },
  { id: "shortcuts.island", page: "shortcuts", title: "Notch shortcuts — active when the notch is in front", terms: [] },

  // Mail
  { id: "mail.autosort", page: "mailOverview", title: "Sort new messages automatically", terms: ["Journal", "Sent by Coucou", "Undo"] },
  { id: "mail.rules", page: "mailRules", title: "Rules", terms: ["Sender", "Subject", "Move to Junk"] },
  { id: "mail.banned", page: "mailBanned", title: "Banned words", terms: [] },
  { id: "mail.vip", page: "mailVIP", title: "VIP", terms: [] },
];

/**
 * Searches the settings index given a query string and page title resolver.
 */
export function searchSettings(
  query: string,
  getPageTitle: (page: PageId) => string,
  entries: SettingsSearchEntry[] = SETTINGS_ENTRIES
): SettingsSearchHit[] {
  const qWords = words(query);
  if (qWords.length === 0) return [];
  const boxes: SettingsSearchHit[] = [];
  const labels: SettingsSearchHit[] = [];

  for (const entry of entries) {
    const titleText = t(entry.title);
    const pageText = getPageTitle(entry.page);
    const labelTexts = entry.terms.map((k) => t(k));
    const res = match(qWords, titleText, pageText, labelTexts)
      ?? match(qWords, entry.title, "", entry.terms);
    if (!res) continue;
    if (res.kind === "box") {
      boxes.push({ entry, id: entry.id });
    } else {
      const index = entry.terms.indexOf(res.label);
      const label = labelTexts.includes(res.label) ? res.label : labelTexts[index] ?? res.label;
      labels.push({ entry, label, id: `${entry.id}|${label}` });
    }
  }

  return [...boxes, ...labels].slice(0, 30);
}

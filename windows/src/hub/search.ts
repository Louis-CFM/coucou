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
  { id: "flow.history", page: "dictation", title: "hub.history", terms: ["hub.page.dictation"] },
  { id: "flow.notes", page: "notes", title: "hub.page.notes", terms: ["notes.live", "notes.key-points"] },
  { id: "flow.insights", page: "insights", title: "hub.page.insights", terms: [] },
  { id: "flow.dictionary", page: "dictionary", title: "hub.page.dictionary", terms: ["hub.replacements"] },
  { id: "flow.snippets", page: "snippets", title: "hub.page.snippets", terms: [] },
  { id: "flow.styles", page: "styles", title: "hub.page.styles", terms: ["hub.cleanup", "hub.style-default", "hub.style-apps"] },
  {
    id: "flow.keys",
    page: "flowsettings",
    title: "hub.settings.keys",
    terms: ["flow.enable", "hub.settings.hold", "flow.edge", "hub.settings.handsfree", "hub.settings.paste-again", "hub.settings.cancel"],
  },
  { id: "flow.ai", page: "flowsettings", title: "flow.ai.title", terms: ["flow.prompt-mode", "flow.translate"] },
  { id: "flow.permission", page: "flowsettings", title: "hub.settings.permission", terms: ["flow.accessibility-open"] },
  { id: "flow.recognition", page: "flowsettings", title: "hub.settings.recognition", terms: ["Dictation language"] },
  { id: "flow.summary", page: "flowsettings", title: "hub.page.notes", terms: ["notes.engine"] },
  { id: "flow.app", page: "flowsettings", title: "hub.settings.app", terms: ["hub.settings.dock", "hub.settings.open-at-launch"] },
  { id: "flow.privacy", page: "flowsettings", title: "hub.settings.privacy", terms: ["hub.settings.keep"] },

  // Notch → General
  { id: "general.demo", page: "general", title: "demo.groupbox.title", terms: [] },
  { id: "general.sound", page: "general", title: "Sound", terms: ["Enable sounds", "Volume", "Open sounds folder", "Reload sounds"] },
  { id: "general.behavior", page: "general", title: "Behavior", terms: ["Open on hover", "Close after", "Hide after", "alerts.all-pills"] },
  { id: "general.display", page: "general", title: "Display", terms: ["Show Mochi on", "Screen with the notch", "Main screen (menu bar)", "Follow the mouse"] },
  { id: "general.vitals", page: "general", title: "vitals.title", terms: ["vitals.toggle"] },
  { id: "general.hotkey", page: "general", title: "Hotkey", terms: ["Show island with shortcut", "Shortcut"] },
  { id: "general.startup", page: "general", title: "Startup", terms: ["Launch at Mac startup"] },
  { id: "general.update", page: "general", title: "update.settings.title", terms: [] },
  { id: "general.recap", page: "general", title: "Weekly recap", terms: ["Keep a history of my coding sessions", "Hide project names in shared images", "Clear history"] },
  { id: "general.language", page: "general", title: "Language", terms: ["Restart Coucou"] },

  // Notch → Pills, Agents, Chat, Integrations, Phone, Voice, Shortcuts
  { id: "pills.main", page: "pills", title: "settings.main-pill", terms: ["Active pills"] },
  { id: "agents.claude", page: "agents", title: "hooks.claude-code.title", terms: ["Answer questions and permissions from terminal sessions in the notch"] },
  { id: "agents.claude-desktop", page: "agents", title: "claude-desktop.chat.title", terms: [] },
  { id: "agents.gemini", page: "agents", title: "hooks.gemini.title", terms: [] },
  { id: "agents.antigravity", page: "agents", title: "hooks.antigravity.title", terms: [] },
  { id: "agents.codex", page: "agents", title: "hooks.codex.title", terms: [] },
  { id: "agents.copilot", page: "agents", title: "hooks.copilot.title", terms: [] },
  { id: "agents.muse", page: "agents", title: "hooks.muse.title", terms: [] },
  { id: "agents.opencode", page: "agents", title: "plugin.opencode.title", terms: [] },
  { id: "agents.amp", page: "agents", title: "plugin.amp.title", terms: [] },
  { id: "agents.hermes", page: "agents", title: "plugin.hermes.title", terms: ["plugin.hermes.approvals"] },
  { id: "agents.plan", page: "agents", title: "plan.title", terms: ["plan.show-in-notch", "Show Codex plan in the notch"] },
  { id: "chat.subscriptions", page: "chat", title: "chat.subscriptions.title", terms: ["chat.subscriptions.use"] },
  { id: "chat.anthropic", page: "chat", title: "chat.anthropic-api.title", terms: ["chat.model", "Anthropic", "Claude"] },
  { id: "chat.others", page: "chat", title: "chat.other-providers.title", terms: ["Google AI", "OpenAI", "DeepSeek", "Gemini"] },
  { id: "chat.local", page: "chat", title: "chat.local.title", terms: ["Ollama", "LM Studio"] },
  {
    id: "integrations.all",
    page: "integrations",
    title: "Integrations",
    terms: [
      "Stripe", "GitHub", "Vercel", "n8n", "Notion", "Resend", "Cal.com", "WhatsApp", "Spotify", "Crypto",
      "Linear", "X", "YouTube", "Figma", "OpenWeather", "Railway", "Supabase", "Hugging Face", "Sentry", "PostHog", "Twilio",
    ],
  },
  { id: "phone.android", page: "phone", title: "phone.title", terms: ["phone.status", "phone.pairing", "phone.approvals"] },
  { id: "voice.wake", page: "voice", title: "«\u202FOK Coucou\u202F» — voice wake word", terms: ["Enable voice command", "Request permissions"] },
  { id: "voice.language", page: "voice", title: "Language", terms: ["voice.listen-language", "voice.language"] },
  { id: "voice.tts", page: "voice", title: "voice.tts-engine", terms: ["voice.tts-gender", "voice.tts-test"] },
  { id: "voice.history", page: "voice", title: "voice.history-title", terms: [] },
  { id: "shortcuts.global", page: "shortcuts", title: "shortcut.group.global", terms: [] },
  { id: "shortcuts.island", page: "shortcuts", title: "shortcut.group.island", terms: [] },

  // Mail
  { id: "mail.autosort", page: "mailOverview", title: "hub.mail.autosort", terms: ["hub.mail.journal", "hub.mail.sent", "hub.mail.undo"] },
  { id: "mail.rules", page: "mailRules", title: "hub.mail.rules", terms: ["hub.mail.field.sender", "hub.mail.field.subject", "hub.mail.do.junk"] },
  { id: "mail.banned", page: "mailBanned", title: "hub.mail.banned", terms: [] },
  { id: "mail.vip", page: "mailVIP", title: "hub.mail.vip", terms: [] },
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
    const res = match(qWords, titleText, pageText, labelTexts);
    if (!res) continue;
    if (res.kind === "box") {
      boxes.push({ entry, id: entry.id });
    } else {
      labels.push({ entry, label: res.label, id: `${entry.id}|${res.label}` });
    }
  }

  return [...boxes, ...labels].slice(0, 30);
}

// WhatsApp (experimental) on the page: what src-tauri/src/whatsapp reports, and the pure rules the
// card and Settings follow — ports of WhatsAppModels.swift (initials, previews) and
// WhatsAppViews.swift (status labels, the time since). Rust only ever sends codes; the words are
// chosen here, in the user's language. Nothing of a message is stored by the page either.

import { N_, t } from "../i18n/i18n";

export const WHATSAPP_ID = "integration_whatsapp";
/** WhatsApp's own green: the pill keeps it whatever, like the brand. */
export const WHATSAPP_GREEN = "#25D366";

export type WaMedia =
  | { kind: "none" | "image" | "video" | "sticker" | "location" | "contact" | "other" }
  | { kind: "audio" | "voice"; seconds: number | null }
  | { kind: "document"; name: string | null };

export interface WaMessage {
  id: string;
  chat: string;
  sender: string;
  senderName: string;
  text: string;
  media: WaMedia;
  /** Unix ms. */
  date: number;
  fromMe: boolean;
  mentionsMe: boolean;
}

export interface WaConversation {
  id: string;
  name: string;
  isGroup: boolean;
  /** Oldest first. */
  messages: WaMessage[];
  unread: number;
  lastActivity: number;
}

export type WaLink =
  | { state: "off" | "badUrl" | "connecting" | "needsQr" | "connected" | "unreachable" | "unauthorized" }
  | { state: "failed"; detail: string };

export type WaSendError =
  | { code: "tooLong" | "tooFast" | "unreachable" | "unauthorized" | "needsQr" }
  | { code: "refused"; detail: string };

/** IslandView in src-tauri/src/whatsapp/mod.rs. */
export interface WaIslandView {
  on: boolean;
  link: WaLink;
  /** Newest first, filters applied. */
  conversations: WaConversation[];
  unread: number;
  sending: boolean;
  sendError: WaSendError | null;
  /** The gateway failed twice in a row: the pill's red dot. */
  down: boolean;
}

export const IDLE_WHATSAPP: WaIslandView = {
  on: false, link: { state: "off" }, conversations: [], unread: 0, sending: false, sendError: null, down: false,
};

/** The page's copy of what Rust keeps. */
export const WhatsApp = {
  view: { ...IDLE_WHATSAPP } as WaIslandView,
};

export type WaWebhook =
  | { state: "off" | "listening" | "registered" }
  | { state: "refused"; detail: string }
  | { state: "portBusy"; port: number };

export type WaInstallStep =
  | { step: "idle" | "checking" | "verifying" | "installing" }
  | { step: "downloading"; megabytes: number }
  | { step: "done"; version: string }
  | { step: "failed"; reason: string };

export interface WaPrefs {
  enabled: boolean;
  gateway: "gowa" | "openwa";
  port: number;
  markReadOnOpen: boolean;
  muteGroups: boolean;
  ignored: string[];
  autoStart: boolean;
  gowaPath: string;
  gowaVersion: string | null;
}

/** SettingsView in src-tauri/src/whatsapp/mod.rs. */
export interface WaSettingsView {
  prefs: WaPrefs;
  url: string;
  defaultUrl: string;
  hasCredential: boolean;
  link: WaLink;
  webhook: WaWebhook;
  qr: string | null;
  me: string | null;
  install: WaInstallStep;
  installed: boolean;
  gowaDir: string;
  pillActive: boolean;
  ignored: { id: string; name: string }[];
}

export type WaTestResult =
  | { result: "needsQr" | "connecting" | "badUrl" | "unreachable" | "unauthorized" }
  | { result: "connected"; who: string }
  | { result: "refused"; detail: string };

export const DEFAULT_URLS = { gowa: "http://127.0.0.1:3000", openwa: "http://127.0.0.1:2785" } as const;
export const DEFAULT_PORT = 47823;

// ── Pure rules ────────────────────────────────────────────────────────────────

/** WAJID.initials: the first letters of the first two words, "#" when there are none. */
export function initials(name: string): string {
  const words = name.split(/[ -]/).filter((w) => /^\p{L}/u.test(w));
  const letters = words.slice(0, 2).map((w) => [...w][0].toUpperCase());
  return letters.length ? letters.join("") : "#";
}

/** WAJID.duration: 12 → "0:12", 75 → "1:15". */
export function duration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/** The label a media gets (English keys, shown with `t()`). */
export const MEDIA_LABELS = {
  image: N_("Photo"),
  video: N_("Video"),
  voice: N_("Voice message"),
  document: N_("Document"),
  sticker: N_("Sticker"),
  location: N_("Location"),
  contact: N_("Contact"),
  other: N_("Message"),
} as const;

/** WAMessage.previewKey: the media's label (if any) and the text that goes with it. */
export function previewParts(m: WaMessage): { label: string | null; value: string } {
  const media = m.media;
  switch (media.kind) {
    case "none": return { label: null, value: m.text };
    case "image": return { label: MEDIA_LABELS.image, value: m.text };
    case "video": return { label: MEDIA_LABELS.video, value: m.text };
    case "audio":
    case "voice": return { label: MEDIA_LABELS.voice, value: media.seconds != null ? duration(media.seconds) : "" };
    case "document": return { label: MEDIA_LABELS.document, value: media.name ?? m.text };
    case "sticker": return { label: MEDIA_LABELS.sticker, value: "" };
    case "location": return { label: MEDIA_LABELS.location, value: "" };
    case "contact": return { label: MEDIA_LABELS.contact, value: "" };
    default: return { label: MEDIA_LABELS.other, value: m.text };
  }
}

/** waPreview: "Marie: see you", "You: ok", "Photo · look", "Voice message": one line. */
export function preview(m: WaMessage, isGroup: boolean): string {
  const { label, value } = previewParts(m);
  let line = label == null ? value : value ? `${t(label)} · ${value}` : t(label);
  line = line.replace(/\n/g, " ");
  if (m.fromMe) return `${t("You")}: ${line}`;
  if (isGroup && m.senderName) return `${m.senderName}: ${line}`;
  return line;
}

/** waTimeAgo: now, 5m, 3h, 2d. */
export function timeAgo(ms: number, now = Date.now()): string {
  const diff = (now - ms) / 1000;
  if (diff < 60) return t("now");
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h`;
  return `${Math.floor(diff / 86400)}d`;
}

/** WhatsAppStatus.label. */
export function linkLabel(link: WaLink): string {
  switch (link.state) {
    case "off": return t("Turned off in Settings");
    case "badUrl": return t("The gateway URL isn’t valid (http://…)");
    case "connecting": return t("Connecting to the gateway…");
    case "needsQr": return t("Scan the QR code in Settings");
    case "connected": return t("Connected");
    case "unreachable": return t("The gateway doesn’t answer: is it running?");
    case "unauthorized": return t("The gateway refuses the credentials");
    case "failed": return link.detail;
  }
}

/** WhatsAppStatus.dot. */
export function linkColor(link: WaLink): string {
  switch (link.state) {
    case "connected": return "#22C55E";
    case "connecting":
    case "needsQr": return "#F5B83D";
    case "off": return "#6B7079";
    default: return "#F4505E";
  }
}

export function sendErrorLabel(e: WaSendError): string {
  switch (e.code) {
    case "tooLong": return t("Too long for one message (4,096 characters at most).");
    case "tooFast": return t("A few replies a minute at most: wait a moment.");
    case "unreachable": return t("The gateway doesn’t answer: is it running?");
    case "unauthorized": return t("The gateway refuses the credentials");
    case "needsQr": return t("Scan the QR code in Settings");
    case "refused": return e.detail;
  }
}

/** The last ten messages of a conversation, oldest first: what the open card shows. */
export function lastMessages(c: WaConversation, count = 10): WaMessage[] {
  return c.messages.slice(-count);
}

/** Enter sends, Shift+Enter is a new line; IME composition never sends. */
export function keyAction(e: { key: string; shiftKey: boolean; isComposing?: boolean }): "send" | "newline" | "back" | null {
  if (e.key === "Escape") return "back";
  if (e.key !== "Enter" || e.isComposing) return null;
  return e.shiftKey ? "newline" : "send";
}

/** Something worth sending: not only spaces and new lines. */
export function canSend(draft: string, sending: boolean): boolean {
  return !sending && draft.trim().length > 0;
}

// ── Settings' words ───────────────────────────────────────────────────────────

/** What a running install says (Settings). */
export function installStepLabel(s: WaInstallStep): string {
  switch (s.step) {
    case "checking": return t("Looking for the latest GOWA…");
    case "downloading": return t("Downloading ({megabytes} MB)…", { megabytes: s.megabytes });
    case "verifying": return t("Checking the download…");
    case "installing": return t("Installing and starting…");
    default: return "";
  }
}

/** Why an install stopped (install.rs's reasons). */
export function installFailure(reason: string): string {
  switch (reason) {
    case "noBuild": return t("No GOWA build for this computer was found on GitHub. Try again later, or set your own gateway under Advanced.");
    case "noChecksum": return t("GOWA's release has no checksum to check the download against: nothing was installed.");
    case "badChecksum": return t("The download doesn't match the file GOWA published: it was deleted, nothing was installed.");
    case "unzipFailed": return t("The download couldn't be unzipped. Try again.");
    default: return t("The download didn't go through. Check your connection and try again.");
  }
}

/** Why the last install stopped, in words; null when it didn't. */
export function installError(s: WaInstallStep): string | null {
  return s.step === "failed" ? installFailure(s.reason) : null;
}

export function isInstalling(s: WaInstallStep): boolean {
  return s.step === "checking" || s.step === "downloading" || s.step === "verifying" || s.step === "installing";
}

/** Whether messages come at once or every 20 s, and why. */
export function webhookLine(w: WaWebhook): string {
  switch (w.state) {
    case "registered": return t("Live: new messages arrive at once.");
    case "portBusy": return t("Port {port} is taken: pick another one. Checking every 20 s meanwhile.", { port: w.port });
    case "refused": return t("The gateway refused Coucou’s address ({detail}). Checking every 20 s instead.", { detail: w.detail });
    default: return t("Checking for new messages every 20 s.");
  }
}

/** "Test connection"'s answer. */
export function testResultLabel(r: WaTestResult): string {
  switch (r.result) {
    case "connected": return t("Connected as {number}.", { number: r.who });
    case "needsQr": return t("The gateway answers. Scan the QR code below with your phone.");
    case "connecting": return t("The gateway answers and is connecting to WhatsApp…");
    case "badUrl": return linkLabel({ state: "badUrl" });
    case "unreachable": return linkLabel({ state: "unreachable" });
    case "unauthorized": return linkLabel({ state: "unauthorized" });
    case "refused": return r.detail;
  }
}

/** The status and QR once there is a gateway to talk to: before the install, "the gateway doesn't
 *  answer" would only confuse. */
export function showsLinkState(v: WaSettingsView): boolean {
  if (v.prefs.gateway !== "gowa" || v.installed || v.url !== "") return true;
  return v.link.state === "connected" || v.link.state === "needsQr";
}

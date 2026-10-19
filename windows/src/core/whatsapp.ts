// The WhatsApp pill on the page: what src-tauri/src/whatsapp reports, and the
// small pure rules the card and Settings share — ports of WhatsAppModels.swift
// (WAJID, WAMessage.previewKey) and the helpers of WhatsAppViews.swift.
// Experimental, as on the Mac: off until turned on in Settings.

import { N_, t } from "../i18n/i18n";

export const WHATSAPP_ID = "integration_whatsapp";
/** whatsAppAccent: WhatsApp's own green, whatever the pill colours. */
export const WHATSAPP_GREEN = "#25D366";

export type WhatsAppMedia =
  | { kind: "none" }
  | { kind: "image" }
  | { kind: "video" }
  | { kind: "audio"; seconds: number | null }
  | { kind: "voice"; seconds: number | null }
  | { kind: "document"; name: string | null }
  | { kind: "sticker" }
  | { kind: "location" }
  | { kind: "contact" }
  | { kind: "other" };

export interface WhatsAppMessage {
  id: string;
  chat: string;
  sender: string;
  senderName: string;
  text: string;
  media: WhatsAppMedia;
  /** Unix seconds. */
  date: number;
  fromMe: boolean;
  mentionsMe: boolean;
}

export interface WhatsAppConversation {
  id: string;
  name: string;
  isGroup: boolean;
  /** Newest last, ten at most. */
  messages: WhatsAppMessage[];
  unread: number;
  lastActivity: number;
}

export type WhatsAppGateway = "gowa" | "openwa";

export interface WhatsAppPrefs {
  enabled: boolean;
  gateway: WhatsAppGateway;
  port: number;
  markReadOnOpen: boolean;
  respectFocus: boolean;
  muteGroups: boolean;
  ignored: string[];
  autostart: boolean;
  installedVersion: string | null;
}

export type WhatsAppLink =
  | { state: "off" }
  | { state: "connecting" }
  | { state: "needsQr" }
  | { state: "connected" }
  | { state: "unreachable" }
  | { state: "unauthorized" }
  | { state: "failed"; detail: string };

export type WhatsAppWebhook =
  | { state: "off" }
  | { state: "listening" }
  | { state: "registered" }
  | { state: "refused"; detail: string }
  | { state: "portBusy" };

export type WhatsAppInstall =
  | { step: "idle" }
  | { step: "checking" }
  | { step: "downloading"; megabytes: number }
  | { step: "verifying" }
  | { step: "installing" }
  | { step: "done"; version: string }
  | { step: "failed"; message: string };

export interface WhatsAppState {
  prefs: WhatsAppPrefs;
  url: string;
  hasCredential: boolean;
  link: WhatsAppLink;
  webhook: WhatsAppWebhook;
  /** The QR to scan, as a data URL. */
  qr: string | null;
  me: string | null;
  conversations: WhatsAppConversation[];
  unread: number;
  sending: boolean;
  sendError: string | null;
  /** The gateway down twice in a row: the pill's small red dot. */
  down: boolean;
  install: WhatsAppInstall;
  installed: boolean;
  focusReadable: boolean;
}

export const DEFAULT_PORT = 47823;

export const IDLE_WHATSAPP: WhatsAppState = {
  prefs: {
    enabled: false, gateway: "gowa", port: DEFAULT_PORT, markReadOnOpen: true, respectFocus: true,
    muteGroups: true, ignored: [], autostart: false, installedVersion: null,
  },
  url: "http://127.0.0.1:3000",
  hasCredential: false,
  link: { state: "off" },
  webhook: { state: "off" },
  qr: null,
  me: null,
  conversations: [],
  unread: 0,
  sending: false,
  sendError: null,
  down: false,
  install: { step: "idle" },
  installed: false,
  focusReadable: true,
};

/** What Rust last said, for the island and Settings alike. */
export const WhatsApp = {
  state: { ...IDLE_WHATSAPP } as WhatsAppState,
};

/** The gateways' own default addresses (WAGatewayKind.defaultURL). */
export function defaultUrl(gateway: WhatsAppGateway): string {
  return gateway === "gowa" ? "http://127.0.0.1:3000" : "http://127.0.0.1:2785";
}

// ── WAJID ─────────────────────────────────────────────────────────────────────

/** "33612345678@s.whatsapp.net" → "+33612345678"; anything else, its user part. */
export function displayNumber(jid: string): string {
  const user = jid.split("@")[0] ?? jid;
  const digits = user.split(":")[0] ?? user;
  return digits !== "" && /^\d+$/.test(digits) ? `+${digits}` : digits;
}

/** Two letters for the avatar: "Marie Dupont" → "MD", "+33 6…" → "#". */
export function initials(name: string): string {
  const letters = name
    .split(/[ -]/)
    .filter((w) => /^\p{L}/u.test(w))
    .slice(0, 2)
    .map((w) => Array.from(w)[0]!.toUpperCase())
    .join("");
  return letters || "#";
}

/** A phone number ("+33 6 12…") or a full chat id ("…@g.us") typed in Settings. */
export function chatFromEntry(raw: string): string | null {
  const entry = raw.trim();
  if (!entry) return null;
  const chat = entry.includes("@") ? entry : `${entry.replace(/\D/g, "")}@s.whatsapp.net`;
  return chat.length > "@s.whatsapp.net".length ? chat : null;
}

// ── Lines ─────────────────────────────────────────────────────────────────────

function duration(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/** WAMessage.previewKey: the media's label (English key, or "") and the text. */
export function previewKey(m: WhatsAppMessage): [string, string] {
  switch (m.media.kind) {
    case "none": return ["", m.text];
    case "image": return [N_("Photo"), m.text];
    case "video": return [N_("Video"), m.text];
    case "audio":
    case "voice": return [N_("Voice message"), m.media.seconds != null ? duration(m.media.seconds) : ""];
    case "document": return [N_("Document"), m.media.name ?? m.text];
    case "sticker": return [N_("Sticker"), ""];
    case "location": return [N_("Location"), ""];
    case "contact": return [N_("Contact"), ""];
    default: return [N_("Message"), m.text];
  }
}

/** "Marie: see you", "You: ok", "Photo · look", "Voice message": one line, media as a label only. */
export function previewLine(m: WhatsAppMessage, isGroup: boolean): string {
  const [key, value] = previewKey(m);
  let line = key ? (value ? `${t(key)} · ${value}` : t(key)) : value;
  line = line.replace(/\n/g, " ");
  if (m.fromMe) return `${t("You")}: ${line}`;
  if (isGroup && m.senderName) return `${m.senderName}: ${line}`;
  return line;
}

/** waTimeAgo: now, 5m, 3h, 2d. */
export function timeAgo(seconds: number, nowMs = Date.now()): string {
  const diff = nowMs / 1000 - seconds;
  if (diff < 60) return t("now");
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h`;
  return `${Math.floor(diff / 86400)}d`;
}

/** WhatsAppStatus.label: what the link reads like, in the card and in Settings. */
export function linkLabel(link: WhatsAppLink): string {
  switch (link.state) {
    case "off": return t("Turned off in Settings");
    case "connecting": return t("Connecting to the gateway…");
    case "needsQr": return t("Scan the QR code in Settings");
    case "connected": return t("Connected");
    case "unreachable": return t("The gateway doesn’t answer: is it running?");
    case "unauthorized": return t("The gateway refuses the credentials");
    case "failed": return link.detail;
  }
}

/** WhatsAppStatus.dot. */
export function linkColor(link: WhatsAppLink): string {
  switch (link.state) {
    case "connected": return "#22C55E";
    case "connecting":
    case "needsQr": return "#F5B83D";
    case "off": return "#6B7079";
    default: return "#F4505E";
  }
}

/** The install is under way: Settings shows its step instead of the button. */
export function installing(step: WhatsAppInstall): boolean {
  return step.step === "checking" || step.step === "downloading" || step.step === "verifying" || step.step === "installing";
}

export function installLabel(step: WhatsAppInstall): string {
  switch (step.step) {
    case "checking": return t("Looking for the latest GOWA…");
    case "downloading": return t("Downloading ({0} MB)…", { 0: step.megabytes });
    case "verifying": return t("Checking the download…");
    case "installing": return t("Installing and starting…");
    default: return "";
  }
}

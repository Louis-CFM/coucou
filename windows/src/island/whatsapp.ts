// WhatsApp's reports → the page (src-tauri/src/whatsapp). The parts of
// WhatsAppController.swift that touch the island: a new message lights the
// pill up with the conversation's name (never the text), Mochi's little
// "happy" emote and the "pop" sound once per burst, the pill's red dot while
// the gateway is down, and the pill going quiet again after a minute.

import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import { WHATSAPP_ID, WhatsApp, type WhatsAppState } from "../core/whatsapp";

export interface WhatsAppHost {
  /** The compact island, by the island's usual rules. */
  reveal(): void;
  emote(name: "happy"): void;
}

let quietTimer: number | null = null;
let lastAnnounce = 0;

export function registerWhatsAppHandlers(island: WhatsAppHost) {
  void onEvent<WhatsAppState>("whatsapp", (s) => applyWhatsApp(s));
  void onEvent<{ name: string; react: boolean }>("whatsapp-announce", (a) => announce(island, a.name, a.react));
  // Rust may have read the gateway before this page listened: ask once.
  void Bridge.whatsappState().then((s) => s && applyWhatsApp(s));
  // The pill on screen: its badge goes (WhatsAppController.clearBadge).
  State.subscribe(() => {
    const task = State.tasks.find((t) => t.id === WHATSAPP_ID);
    if (task && State.focusId === WHATSAPP_ID && task.pillBadge === "finished") task.pillBadge = null;
  });
}

/** A snapshot from Rust (or the answer to whatsappState). */
export function applyWhatsApp(next: WhatsAppState) {
  WhatsApp.state = next;
  const task = State.tasks.find((t) => t.id === WHATSAPP_ID);
  if (task) {
    // The discreet error pill: a red dot while the gateway is down, nothing more.
    if (next.down) task.pillBadge = "error";
    else if (task.pillBadge === "error") task.pillBadge = null;
    if (next.link.state === "off" && task.state === "finished") resetTask();
  }
  State.notify();
}

function announce(island: WhatsAppHost, name: string, react: boolean) {
  if (State.paused) return;
  const task = State.tasks.find((t) => t.id === WHATSAPP_ID);
  if (!task) return;
  task.state = "finished";
  // Only the conversation's name on the pill, never the text.
  task.steps = [name];
  task.stepIndex = 0;
  if (State.focusId !== WHATSAPP_ID) task.pillBadge = "finished";
  lastAnnounce = Date.now();
  if (react) {
    island.emote("happy");
    Sound.play("pop");
    island.reveal();
  }
  if (quietTimer != null) window.clearTimeout(quietTimer);
  quietTimer = window.setTimeout(() => {
    quietTimer = null;
    if (Date.now() - lastAnnounce < 59_000) return;
    const t = State.tasks.find((x) => x.id === WHATSAPP_ID);
    if (!t || t.state !== "finished") return;
    resetTask();
    State.notify();
  }, 60_000);
  State.notify();
}

function resetTask() {
  const t = State.tasks.find((x) => x.id === WHATSAPP_ID);
  if (!t) return;
  t.state = "idle";
  t.steps = [];
  t.stepIndex = 0;
  if (t.pillBadge === "finished") t.pillBadge = null;
}

// New versions in the island — port of MacUpdater's card side. Rust
// (src-tauri/src/update.rs) does the looking, the downloading and the
// schedule; it offers the card ("update-offer") and the island opens it only
// when nothing else waits there, then says so (`update_shown`), which starts
// the day before the same question or version comes back.

import { Bridge, onEvent } from "../core/bridge";
import type { BotEmoteName, IslandViewName } from "../core/layout";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import { NO_UPDATE, mayOffer, type UpdateOffer, type UpdateStatus } from "../core/update";
import { updateWaiting, type Later } from "../whats-new/whats-new";

/**
 * "Later" for the blue Mochi (whats-new.ts): which version, and when. Rust
 * keeps its own snooze for the card coming back by itself; this one only says
 * whether Mochi stays blue and a click opens on the update. A per-install
 * convenience, so the webview's storage is enough: lost, Mochi is blue again.
 */
const LATER_KEY = "coucou.update.later";

function readLater(): Later | null {
  try {
    const raw = window.localStorage?.getItem(LATER_KEY);
    if (!raw) return null;
    const v = JSON.parse(raw) as Partial<Later>;
    return typeof v.version === "string" && typeof v.at === "number" ? { version: v.version, at: v.at } : null;
  } catch {
    return null;
  }
}

function writeLater(later: Later) {
  try {
    window.localStorage?.setItem(LATER_KEY, JSON.stringify(later));
  } catch {
    // Storage refused: the blue only comes back sooner.
  }
}

/** What the update card needs from the island. */
export interface UpdateHost {
  alert(view: IslandViewName): void;
  collapse(): void;
  emote(name: BotEmoteName): void;
}

class UpdateController {
  status: UpdateStatus = { ...NO_UPDATE };
  /** The card asks "Get new versions from the island?". */
  asking = false;
  private host: UpdateHost | null = null;

  async register(host: UpdateHost) {
    this.host = host;
    const status = await Bridge.updateStatus();
    if (status) this.status = status;
    await onEvent<UpdateStatus>("update-status", (s) => {
      this.status = s;
      State.notify();
      this.syncTray();
    });
    await onEvent<UpdateOffer>("update-offer", (offer) => this.offer(offer));
    this.syncTray();
    // A day after Later the blue comes back, island hidden or not: a look every half hour.
    if (!this.trayLook) {
      const look = setInterval(() => this.syncTray(), 30 * 60 * 1000) as unknown as { unref?: () => void };
      look.unref?.(); // the tests run this in Node: the timer must not keep them alive
      this.trayLook = true;
    }
  }

  private trayBlue = false;
  private trayLook = false;

  /** The tray Mochi follows: blue while a new version waits, like the island's. */
  private syncTray() {
    const on = this.waiting();
    if (on === this.trayBlue) return;
    this.trayBlue = on;
    void Bridge.trayUpdateHint(on);
  }

  offer(offer: UpdateOffer) {
    const host = this.host;
    if (!host) return;
    const now = {
      paused: State.paused,
      pending: State.pendingApproval != null,
      mode: State.mode,
      view: State.view,
    };
    if (!mayOffer(offer, now)) return;
    if (offer === "ask") {
      this.asking = true;
      void Bridge.updateShown("ask");
      host.alert("update");
      return;
    }
    // Rust offers only a version that is out; the status may just be a moment behind.
    if (!this.status.latest && offer === "announce") return;
    this.asking = false;
    host.alert("update");
    if (offer === "announce") {
      void Bridge.updateShown("announce");
      host.emote("surprised");
      Sound.play("peek");
    }
  }

  /** Tray → "Update Coucou to X…", Settings → Install X. */
  show() {
    this.offer("show");
  }

  answer(yes: boolean) {
    this.asking = false;
    void Bridge.updateSetConsent(yes);
    this.syncTray();
    this.host?.collapse();
  }

  install() {
    void Bridge.updateInstall();
  }

  openPage() {
    void Bridge.updateOpenPage();
  }

  later() {
    const version = this.status.latest?.version;
    if (version) {
      this.laterMemo = { version, at: Date.now() };
      writeLater(this.laterMemo);
    }
    void Bridge.updateLater();
    this.host?.collapse();
    State.notify();
    this.syncTray();
  }

  private laterMemo: Later | null | undefined;

  /** A newer version waits for the user (Mochi turns blue, a click opens on it). */
  waiting(nowMs = Date.now()): boolean {
    if (this.laterMemo === undefined) this.laterMemo = readLater();
    return !this.asking && updateWaiting(this.status, this.laterMemo, nowMs);
  }

  /** OK on a failed update or on "up to date". */
  dismiss() {
    void Bridge.updateDismiss();
    this.host?.collapse();
  }
}

export const Updates = new UpdateController();

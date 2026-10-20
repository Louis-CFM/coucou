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
    });
    await onEvent<UpdateOffer>("update-offer", (offer) => this.offer(offer));
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
    this.host?.collapse();
  }

  install() {
    void Bridge.updateInstall();
  }

  openPage() {
    void Bridge.updateOpenPage();
  }

  later() {
    void Bridge.updateLater();
    this.host?.collapse();
  }

  /** OK on a failed update or on "up to date". */
  dismiss() {
    void Bridge.updateDismiss();
    this.host?.collapse();
  }
}

export const Updates = new UpdateController();

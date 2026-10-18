import { providerForPill } from "../core/providers";
// Island-side adapter. The island still owns every integration and permission;
// the habitat receives a small presentation snapshot and explicit user clicks.
import { Bridge, emitToWindow, onEvent } from "../core/bridge";
import { Spotify, SPOTIFY_ID } from "../core/spotify";
import { State } from "../core/state";
import { PET_EVENTS, companionIdentities, type CompanionsSnapshot } from "../mochi/companions";
import type { Outfit } from "../mochi/wardrobe";

export class CompanionsLink {
  supported = false;
  private launched = false;
  private key = "";
  private configuration = "";
  private pending = false;
  private dirty = false;
  private showing = false;
  private band: CompanionsSnapshot["band"] = null;

  private open: (id: string, view?: string) => void;
  private outfit: () => Outfit;

  constructor(open: (id: string, view?: string) => void, outfit: () => Outfit) {
    this.open = open;
    this.outfit = outfit;
  }

  async init() {
    // A missing surface (Windows, GNOME Wayland or a creation error) uses the
    // original single desktop companion. Nothing disappears without a fallback.
    this.supported = await Bridge.companionsConfigure(false, 0) != null;
    if (!this.supported) return;
    await onEvent(PET_EVENTS.ready, () => { this.key = ""; void this.sync(); });
    await onEvent<{ pillId: string; view?: string }>(PET_EVENTS.open, e => {
      if (!State.settings.companionMode || !State.tasks.some(t => t.id === e.pillId)) return;
      this.open(e.pillId, e.view);
    });
    await onEvent<{ action: string }>(PET_EVENTS.action, e => {
      if (e.action !== "pause" || !State.settings.companionMode) return;
      State.paused = !State.paused;
      State.notify();
    });
    await onEvent("companions-layout-changed", () => { this.configuration = ""; void this.sync(); });
    State.subscribe(() => void this.sync());
  }

  async launch() { this.launched = true; await this.sync(); }
  private get enabled() { return this.supported && this.launched && State.settings.companionMode; }
  get active() { return this.enabled && this.showing; }

  async sync() {
    if (!this.supported || !this.launched) return;
    if (this.pending) { this.dirty = true; return; }
    this.pending = true;
    try {
      do {
        this.dirty = false;
        const snapshot: CompanionsSnapshot = {
          enabled: this.enabled, paused: State.paused, motion: State.settings.companionMotion,
          language: State.settings.language, presented: State.mode === "expanded" ? State.focusId : null,
          pets: companionIdentities(State.tasks.map(t => State.chatBusyProvider && providerForPill(t.id) === State.chatBusyProvider ? {...t,state:"thinking" as const} : t), State.pendingApproval, State.spotifyPlaying, this.outfit(), new Set(Spotify.state.running ? [SPOTIFY_ID] : [])),
        };
        const configuration = JSON.stringify([snapshot.enabled, snapshot.pets.length, State.settings.screen, State.settings.companionTopClearance, State.settings.companionBarMode]);
        if (configuration !== this.configuration) {
          const configured = await Bridge.companionsConfigure(snapshot.enabled, snapshot.pets.length);
          if (!configured) {
            // Keep the singleton fallback for this launch. Retrying later could
            // leave both renderers on screen after the singleton has flown out.
            this.supported = false;
            snapshot.enabled = false;
          } else { this.configuration = configuration; this.band = configured.band; }
        }
        snapshot.band = this.band;
        this.showing = snapshot.enabled;
        const key = JSON.stringify(snapshot);
        if (key !== this.key) {
          this.key = key;
          await emitToWindow("companions", PET_EVENTS.state, snapshot);
        }
      } while (this.dirty);
    } finally { this.pending = false; }
  }
}

// SoundEngine — port of SoundEngine.swift.
// The 29 WAVs are the macOS app's own files (see SOUNDS_DIR in vite.config.ts);
// they are served at /sounds/<name>.wav. Default volume 0.12, slider range 0–0.2,
// exactly like the Mac player, and several sounds may overlap.
// A file of the user's own in the sounds folder (src-tauri/src/sounds.rs)
// replaces a sound; one that doesn't decode falls back to the built-in one.

import { Bridge } from "./bridge";

export const SOUND_NAMES = [
  "peek", "open", "close", "hover", "blip", "slap", "annoyed", "dizzy", "greet",
  "work", "finish", "error", "approval", "question", "approve", "gulp", "tick",
  "send", "love", "pop", "proud", "wink", "yawn", "attach", "think", "search",
  "rate", "sleep", "greeting",
] as const;

export type SoundName = (typeof SOUND_NAMES)[number];

class SoundEngine {
  enabled = true;
  volume = 0.12;

  private ctx: AudioContext | null = null;
  private master: GainNode | null = null;
  private buffers = new Map<string, AudioBuffer>();
  private loading: Promise<void> | null = null;
  private idleTimer: number | null = null;
  /** The sounds a file of the user's own replaces, as last loaded. */
  customized = new Set<string>();
  /** Sounds still playing, by name, so one can be faded out (the greeting). */
  private playing = new Map<string, Set<{ src: AudioBufferSourceNode; gain: GainNode }>>();

  /** Creates the context and decodes every WAV. Safe to call more than once. */
  preload(): Promise<void> {
    if (this.loading) return this.loading;
    this.loading = (async () => {
      const Ctor = window.AudioContext ?? (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
      if (!Ctor) return;
      const ctx = new Ctor();
      this.ctx = ctx;
      const master = ctx.createGain();
      master.gain.value = this.volume;
      master.connect(ctx.destination);
      this.master = master;
      await this.loadAll(ctx);
    })();
    return this.loading;
  }

  /** Reads the sounds folder again (Settings → Reload sounds). */
  async reload(): Promise<void> {
    await this.preload();
    if (this.ctx) await this.loadAll(this.ctx);
  }

  private async loadAll(ctx: AudioContext) {
    const own = new Set((await Bridge.customSounds(SOUND_NAMES)) ?? []);
    const customized = new Set<string>();
    await Promise.all(
      SOUND_NAMES.map(async (name) => {
        if (own.has(name)) {
          try {
            const bytes = await Bridge.customSound(name);
            if (bytes && bytes.byteLength > 0) {
              this.buffers.set(name, await ctx.decodeAudioData(bytes));
              customized.add(name);
              return;
            }
          } catch {
            /* not a format this webview decodes: the built-in sound stays */
          }
        }
        try {
          const res = await fetch(`/sounds/${name}.wav`);
          if (!res.ok) return;
          const buf = await ctx.decodeAudioData(await res.arrayBuffer());
          this.buffers.set(name, buf);
        } catch {
          /* a missing sound must never break the island */
        }
      }),
    );
    this.customized = customized;
  }

  /** WebView2 can hand us a suspended context; call after any user input. */
  resume() {
    if (this.idleTimer != null) {
      window.clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
    void this.ctx?.resume();
  }

  /**
   * Called when the island goes quiet. A running AudioContext keeps an audio
   * thread and its render quantum alive even with nothing playing, which shows
   * up as a steady trickle of CPU on a machine that is supposed to be idle.
   *
   * The delay covers the tail of whatever just played — suspending mid-sound
   * would clip it — and `play()` resumes the context on its own.
   */
  idle() {
    if (!this.ctx || this.ctx.state !== "running" || this.idleTimer != null) return;
    this.idleTimer = window.setTimeout(() => {
      this.idleTimer = null;
      void this.ctx?.suspend();
    }, 1500);
  }

  setVolume(v: number) {
    this.volume = Math.max(0, Math.min(0.2, v));
    if (this.master) this.master.gain.value = this.volume;
  }

  setEnabled(on: boolean) {
    this.enabled = on;
  }

  play(name: SoundName | string) {
    if (!this.enabled) return;
    const ctx = this.ctx;
    const master = this.master;
    const buf = this.buffers.get(name);
    if (!ctx || !master || !buf) return;
    if (this.idleTimer != null) {
      window.clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
    if (ctx.state === "suspended") void ctx.resume();
    const src = ctx.createBufferSource();
    src.buffer = buf;
    const gain = ctx.createGain();
    src.connect(gain);
    gain.connect(master);
    const voice = { src, gain };
    let voices = this.playing.get(name);
    if (!voices) this.playing.set(name, (voices = new Set()));
    voices.add(voice);
    src.onended = () => {
      voices.delete(voice);
      gain.disconnect();
    };
    src.start();
  }

  /** Fades every playing copy of `name` to silence over `seconds`, then stops it. */
  fadeOut(name: string, seconds: number) {
    const ctx = this.ctx;
    const voices = this.playing.get(name);
    if (!ctx || !voices) return;
    const t = ctx.currentTime;
    for (const { src, gain } of voices) {
      gain.gain.cancelScheduledValues(t);
      gain.gain.setValueAtTime(gain.gain.value, t);
      gain.gain.linearRampToValueAtTime(0, t + seconds);
      try {
        src.stop(t + seconds);
      } catch {
        /* already stopped */
      }
    }
  }
}

export const Sound = new SoundEngine();

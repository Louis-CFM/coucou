const SOUND_NAMES = [
  "annoyed",
  "approval",
  "approve",
  "attach",
  "blip",
  "close",
  "dizzy",
  "error",
  "finish",
  "greet",
  "gulp",
  "hover",
  "love",
  "open",
  "peek",
  "pop",
  "proud",
  "question",
  "rate",
  "search",
  "send",
  "slap",
  "sleep",
  "think",
  "tick",
  "wink",
  "work",
  "yawn",
] as const;

export type SoundName = (typeof SOUND_NAMES)[number];

const POOL_SIZE = 3;

export class AudioService {
  private ctx: AudioContext | null = null;
  private pools = new Map<string, AudioBuffer[]>();
  private poolIndex = new Map<string, number>();
  private volume = 0.12;
  private enabled = true;
  private loadPromise: Promise<void> | null = null;

  async preload(basePath = "/sounds"): Promise<void> {
    if (this.loadPromise) return this.loadPromise;
    this.loadPromise = this.doPreload(basePath);
    return this.loadPromise;
  }

  private async doPreload(basePath: string): Promise<void> {
    if (typeof window === "undefined") return;

    try {
      this.ctx = new AudioContext();
    } catch {
      return;
    }

    await Promise.all(
      SOUND_NAMES.map(async (name) => {
        const url = `${basePath}/${name}.wav`;
        try {
          const res = await fetch(url);
          if (!res.ok) return;
          const buf = await res.arrayBuffer();
          if (!this.ctx) return;
          const decoded = await this.ctx.decodeAudioData(buf.slice(0));
          const pool: AudioBuffer[] = [];
          for (let i = 0; i < POOL_SIZE; i++) {
            pool.push(decoded);
          }
          this.pools.set(name, pool);
          this.poolIndex.set(name, 0);
        } catch {
          /* missing or corrupt file — skip */
        }
      }),
    );
  }

  setVolume(volume: number): void {
    this.volume = Math.max(0, Math.min(1, volume));
  }

  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
  }

  async play(name: string): Promise<void> {
    if (!this.enabled) return;
    if (!this.ctx) {
      await this.preload();
    }
    const ctx = this.ctx;
    if (!ctx) return;

    const pool = this.pools.get(name);
    if (!pool || pool.length === 0) return;

    if (ctx.state === "suspended") {
      try {
        await ctx.resume();
      } catch {
        return;
      }
    }

    const idx = this.poolIndex.get(name) ?? 0;
    const buffer = pool[idx % pool.length];
    this.poolIndex.set(name, (idx + 1) % pool.length);

    const source = ctx.createBufferSource();
    source.buffer = buffer;
    const gain = ctx.createGain();
    gain.gain.value = this.volume;
    source.connect(gain);
    gain.connect(ctx.destination);
    source.start(0);
  }
}

export const audio = new AudioService();

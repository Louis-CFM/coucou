/** Own one reply, including cancellation while Audio.play() is still pending. */
export class VoiceAudio {
  private current: { audio: HTMLAudioElement; cancel: () => void } | null = null;
  private create: (source: string) => HTMLAudioElement;
  constructor(create = (source: string) => new Audio(source)) { this.create = create; }

  cancel() {
    this.current?.cancel();
  }

  async play(source: string): Promise<boolean> {
    this.cancel();
    let url: string | null = null;
    try {
      const match = /^data:(audio\/[\w.+-]+);base64,([\s\S]*)$/.exec(source);
      const encoded = match?.[2] ?? source;
      if (encoded.length > 12 * 1024 * 1024) return false;
      const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
      // The app deliberately permits blob: media and blocks data: media.
      // Decode inside this document instead of weakening its content policy.
      url = URL.createObjectURL(new Blob([bytes], { type: match?.[1] ?? "audio/mpeg" }));
      const audio = this.create(url);
      return await new Promise<boolean>((resolve) => {
        let finished = false;
        const clip = { audio, cancel: () => { audio.pause(); done(true); audio.src = ""; } };
        const done = (success: boolean) => {
          if (finished) return;
          finished = true;
          if (this.current === clip) this.current = null;
          audio.onended = audio.onerror = null;
          if (url) { URL.revokeObjectURL(url); url = null; }
          resolve(success);
        };
        this.current = clip;
        audio.onended = () => done(true);
        audio.onerror = () => done(false);
        // A paused element need not emit ended/error. Cancellation resolves the
        // waiter itself, and a late play() resolution cannot restart the reply.
        void audio.play().then(() => { if (finished) audio.pause(); }, () => done(false));
      });
    } catch {
      if (url) URL.revokeObjectURL(url);
      this.current = null;
      return false;
    }
  }
}

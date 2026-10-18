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
    try {
      const audio = this.create(source.startsWith("data:audio/") ? source : `data:audio/mpeg;base64,${source}`);
      return await new Promise<boolean>((resolve) => {
        let finished = false;
        const clip = { audio, cancel: () => { audio.pause(); done(true); audio.src = ""; } };
        const done = (success: boolean) => {
          if (finished) return;
          finished = true;
          if (this.current === clip) this.current = null;
          audio.onended = audio.onerror = null;
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
      this.current = null;
      return false;
    }
  }
}

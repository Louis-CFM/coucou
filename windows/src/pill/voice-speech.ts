import { onEvent } from "../core/bridge";
import { FlowBridge } from "../core/flow";
import { VoiceAudio } from "./voice-audio";

export interface SpokenReply {
  id: number;
  text: string;
  lang: string | null;
  audio: string | null;
  gender: "female" | "male";
  allowSystemFallback?: boolean;
}
type AudioPort = Pick<VoiceAudio, "play" | "cancel">;

/** Playback belongs to the mapped surface, which may be a pet or the old pill. */
export class VoiceSpeech {
  private epoch = 0;
  private cancelSystem: (() => void) | null = null;
  private audio: AudioPort;
  private changed: (speaking: boolean) => void;
  constructor(changed: (speaking: boolean) => void = () => {}, audio: AudioPort = new VoiceAudio()) {
    this.changed = changed;
    this.audio = audio;
  }
  cancel() {
    this.epoch++;
    window.speechSynthesis?.cancel();
    this.audio.cancel();
    this.cancelSystem?.();
    this.cancelSystem = null;
    this.changed(false);
  }
  async say(reply: SpokenReply) {
    this.cancel();
    const epoch = this.epoch;
    let played = false;
    this.changed(true);
    try {
      played = !!reply.audio && await this.audio.play(reply.audio);
      if (!played && epoch === this.epoch && reply.allowSystemFallback !== false) played = await this.system(reply, epoch);
    } finally {
      if (epoch === this.epoch) { this.cancelSystem = null; this.changed(false); }
      void FlowBridge.voiceDone(reply.id, played && epoch === this.epoch);
    }
  }
  private async system(reply: SpokenReply, epoch: number): Promise<boolean> {
    const synth = window.speechSynthesis;
    if (synth && synth.getVoices().length === 0) {
      await new Promise<void>(resolve => {
        synth.addEventListener("voiceschanged", () => resolve(), { once: true });
        setTimeout(resolve, 600);
      });
    }
    if (epoch !== this.epoch) return false;
    if (!synth || !synth.getVoices().length) return !!(await FlowBridge.sayNative(reply.text, reply.lang));
    const want = (reply.lang ?? navigator.language).toLowerCase();
    const short = want.split("-")[0];
    const voices = synth.getVoices();
    const matching = voices.filter(v => v.lang.toLowerCase() === want)
      .concat(voices.filter(v => v.lang.toLowerCase().split(/[-_]/)[0] === short && v.lang.toLowerCase() !== want));
    const female = /(female|woman|zira|hortense|julie|denise|aria|jenny|samantha|amelie|eloise)/i;
    const male = /(male|man\b|david|paul|guy|henri|claude|mark|thomas)/i;
    const voice = matching.find(v => reply.gender === "male" ? male.test(v.name) && !female.test(v.name) : female.test(v.name)) ?? matching[0];
    return new Promise<boolean>(resolve => {
      this.cancelSystem = () => resolve(false);
      const utterance = new SpeechSynthesisUtterance(reply.text);
      if (voice) utterance.voice = voice;
      utterance.lang = voice?.lang ?? reply.lang ?? navigator.language;
      utterance.onend = () => resolve(true);
      utterance.onerror = () => resolve(false);
      synth.speak(utterance);
    });
  }
}

export async function registerVoiceSpeech(changed: (speaking: boolean) => void = () => {}, audio?: AudioPort) {
  const speaker = new VoiceSpeech(changed, audio);
  await Promise.all([
    onEvent<SpokenReply>("voice-say", reply => void speaker.say(reply)),
    onEvent("voice-cancel", () => speaker.cancel()),
  ]);
  return speaker;
}

// Always-on wake word, fully local. The microphone is watched with a cheap
// energy gate; only short bursts of speech are sent to the local Whisper worker,
// and the transcript is fuzzy-matched against the wake word. Whisper copes with
// accents far better than the Windows recognizer, which has no Indonesian model.

import { Bridge } from "./bridge";
import { Sound } from "./sound";
import { State } from "./state";
import { Voice, encodeWav, uint8ToBase64 } from "./voice";

const SAMPLE_RATE = 16000;
const BUFFER = 2048; // 128 ms
const PREROLL_BUFFERS = 4;
const END_SILENCE_BUFFERS = 5; // ~640 ms of quiet closes a phrase
const MAX_BUFFERS = 40; // ~5 s cap on a single phrase
const MIN_SPEECH_SAMPLES = SAMPLE_RATE * 0.3;
const MAX_WORDS = 4; // a wake phrase is short: "hey coucou", not a sentence
const RESUME_DELAY_MS = 1200; // let TTS and dictation echo die out

const BASE_TARGETS = ["coucou", "cucu", "cuco", "kuku", "kuko", "coco", "koko", "mochi", "moci"];
const GREETINGS = new Set(["hey", "hei", "hai", "hay", "hi", "halo", "hello", "ok", "oke", "okay", "ya"]);

function normalize(text: string): string {
  return text
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function levenshtein(a: string, b: string): number {
  const prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let diag = prev[0];
    prev[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = prev[j];
      prev[j] = Math.min(prev[j] + 1, prev[j - 1] + 1, diag + (a[i - 1] === b[j - 1] ? 0 : 1));
      diag = tmp;
    }
  }
  return prev[b.length];
}

function similar(a: string, b: string): boolean {
  if (a === b) return true;
  const longest = Math.max(a.length, b.length);
  if (longest < 4) return false;
  return 1 - levenshtein(a, b) / longest >= 0.75;
}

/** True when a short transcript sounds like the wake word. Exported for tests. */
export function matchesWake(text: string, custom: string): boolean {
  const norm = normalize(text);
  if (!norm) return false;
  const words = norm.split(" ").filter((w) => !GREETINGS.has(w));
  if (words.length === 0 || words.length > MAX_WORDS) return false;

  const targets = new Set(BASE_TARGETS);
  const customWords = normalize(custom)
    .split(" ")
    .filter((w) => w && !GREETINGS.has(w));
  for (const w of customWords) targets.add(w);
  if (customWords.length > 1) targets.add(customWords.join(""));

  // Whisper may split one word ("ku ku", "cou cou"): try adjacent pairs joined too.
  const candidates = [...words];
  for (let i = 0; i < words.length - 1; i++) candidates.push(words[i] + words[i + 1]);

  return candidates.some((c) => [...targets].some((t) => similar(c, t)));
}

class WakeEngine {
  private stream: MediaStream | null = null;
  private ctx: AudioContext | null = null;
  private processor: ScriptProcessorNode | null = null;
  private gain: GainNode | null = null;
  private deviceKey = "";
  private starting = false;
  private onWake: (() => void) | null = null;

  private preroll: Float32Array[] = [];
  private segment: Float32Array[] = [];
  private inSpeech = false;
  private loudRun = 0;
  private quietRun = 0;
  private floor = 0.005;
  private busy = false;
  private resumeAt = 0;

  /** Call once; afterwards sync() follows the settings. */
  start(onWake: () => void) {
    this.onWake = onWake;
    void this.sync();
  }

  async sync() {
    const wanted = State.settings.voiceEnabled;
    const key = State.settings.voiceInputDevice || "";
    if (!wanted) {
      this.stop();
      return;
    }
    if (this.stream && key === this.deviceKey) return;
    if (this.starting) return;
    this.stop();
    await this.open(key);
  }

  private async open(deviceKey: string) {
    this.starting = true;
    try {
      const constraints: MediaTrackConstraints = {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: false,
      };
      if (deviceKey && deviceKey !== "default") constraints.deviceId = { exact: deviceKey };
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: constraints });
      this.deviceKey = deviceKey;

      this.ctx = new AudioContext({ sampleRate: SAMPLE_RATE });
      const source = this.ctx.createMediaStreamSource(this.stream);
      this.gain = this.ctx.createGain();
      this.gain.gain.value = State.settings.voiceMicGain || 2.0;
      this.processor = this.ctx.createScriptProcessor(BUFFER, 1, 1);
      this.processor.onaudioprocess = (e) => this.onBuffer(e.inputBuffer.getChannelData(0));
      source.connect(this.gain);
      this.gain.connect(this.processor);
      this.processor.connect(this.ctx.destination);

      void Bridge.wakeServerWarmUp();
      void Bridge.log("wake engine listening (local whisper)");
    } catch (err) {
      void Bridge.log(`wake engine could not open the microphone: ${String(err)}`);
      this.stop();
    } finally {
      this.starting = false;
    }
  }

  stop() {
    if (this.processor) {
      this.processor.onaudioprocess = null;
      this.processor.disconnect();
      this.processor = null;
    }
    this.gain?.disconnect();
    this.gain = null;
    if (this.stream) {
      for (const t of this.stream.getTracks()) t.stop();
      this.stream = null;
    }
    if (this.ctx) {
      void this.ctx.close();
      this.ctx = null;
    }
    this.resetSegment();
  }

  private resetSegment() {
    this.preroll = [];
    this.segment = [];
    this.inSpeech = false;
    this.loudRun = 0;
    this.quietRun = 0;
  }

  private paused(): boolean {
    return State.isVoiceListening || State.isVoiceSpeaking || State.isVoiceTranscribing;
  }

  private onBuffer(input: Float32Array) {
    if (this.paused()) {
      this.resetSegment();
      this.resumeAt = performance.now() + RESUME_DELAY_MS;
      return;
    }
    if (performance.now() < this.resumeAt) return;

    // Settings can change while this runs: follow the boost live.
    if (this.gain) this.gain.gain.value = State.settings.voiceMicGain || 2.0;

    const buf = new Float32Array(input);
    let sq = 0;
    for (let i = 0; i < buf.length; i++) sq += buf[i] * buf[i];
    const rms = Math.sqrt(sq / buf.length);
    const loud = rms > Math.max(0.015, this.floor * 3);

    if (!this.inSpeech) {
      if (!loud) this.floor = this.floor * 0.95 + rms * 0.05;
      this.preroll.push(buf);
      if (this.preroll.length > PREROLL_BUFFERS) this.preroll.shift();
      this.loudRun = loud ? this.loudRun + 1 : 0;
      if (this.loudRun >= 2) {
        this.inSpeech = true;
        this.segment = [...this.preroll];
        this.quietRun = 0;
      }
      return;
    }

    this.segment.push(buf);
    this.quietRun = loud ? 0 : this.quietRun + 1;
    if (this.quietRun >= END_SILENCE_BUFFERS || this.segment.length >= MAX_BUFFERS) {
      const chunks = this.segment;
      this.resetSegment();
      this.finish(chunks);
    }
  }

  private finish(chunks: Float32Array[]) {
    const total = chunks.reduce((n, c) => n + c.length, 0);
    if (total < MIN_SPEECH_SAMPLES || this.busy) return;

    const merged = new Float32Array(total);
    let offset = 0;
    for (const c of chunks) {
      merged.set(c, offset);
      offset += c.length;
    }

    let peak = 0;
    for (let i = 0; i < merged.length; i++) peak = Math.max(peak, Math.abs(merged[i]));
    if (peak > 0) {
      const gain = Math.min(25, 0.85 / peak);
      for (let i = 0; i < merged.length; i++) merged[i] *= gain;
    }

    const wakeWord = State.settings.voiceWakeWord || "Hey Coucou";
    const lang = (State.settings.voiceLanguage || "id-ID").split("-")[0];
    const prompt = `Hey Coucou. ${wakeWord}.`;
    const wav = uint8ToBase64(encodeWav(merged, SAMPLE_RATE));

    this.busy = true;
    Bridge.wakeTranscribe(wav, lang, prompt)
      .then((text) => {
        const heard = text.trim();
        if (!heard) return;
        const hit = matchesWake(heard, wakeWord);
        void Bridge.log(`wake heard: '${heard}' -> ${hit ? "MATCH" : "no match"}`);
        if (hit && !this.paused()) this.trigger();
      })
      .catch((err) => void Bridge.log(`wake transcribe failed: ${String(err)}`))
      .finally(() => {
        this.busy = false;
      });
  }

  private trigger() {
    Sound.play("greet");
    this.onWake?.();
    void Voice.startListening();
  }
}

export const Wake = new WakeEngine();

// The chat's mic: words appear while you speak, and it stops by itself once
// you do.
//
// The microphone is read sample by sample and a voice-activity detector cuts
// it into phrases at the short pauses of speech. Each finished phrase goes to
// the saved speech-to-text model (Bridge.transcribe) as a small WAV, so the
// text grows phrase by phrase; while a long phrase is still being spoken it is
// also re-read now and then, so words show before the pause. Silence is never
// sent: a phrase needs real voiced time, and Whisper's stock inventions on
// noise ("Thank you.", "Thanks for watching!") are dropped.
//
// Requests stay under free-tier limits (Groq: 20 a minute): finished phrases
// always go, in order, waiting for the minute window if they must; the
// in-progress re-reads only use the room left over.

import { Bridge } from "../core/bridge";

// ── Tuning knobs (real rooms and microphones differ) ──────────────────────────

/** Below this RMS nothing counts as speech, however quiet the room (~-40 dBFS). */
const MIN_SPEECH_RMS = 0.012;
/** Speech is this many times louder than the room's own noise floor. */
const OVER_FLOOR = 3;
/** A pause this long closes a phrase (it gets transcribed). */
const PHRASE_PAUSE_MS = 550;
/** Silence this long after speaking ends the dictation (it gets sent). */
const END_SILENCE_MS = 1600;
/** A phrase needs this much voiced audio to be worth transcribing. */
const MIN_VOICED_MS = 250;
/** Audio kept from just before speech starts, so the first syllable isn't cut. */
const PRE_ROLL_MS = 300;
/** A phrase spoken without any pause is cut here anyway. */
const MAX_PHRASE_MS = 15_000;
/** Re-read the phrase being spoken at most this often. */
const INTERIM_EVERY_MS = 1500;
/** Requests a minute: finished phrases may use up to the first, re-reads only up to the second. */
const PER_MINUTE = 18;
const INTERIM_PER_MINUTE = 11;
/** However long it goes, a dictation stops here. */
const MAX_TOTAL_MS = 120_000;

const RATE = 16_000; // what Whisper works at: smaller uploads

export type DictationPhase = "listening" | "transcribing";

export interface DictationOptions {
  /** Stop with nothing if no speech starts within this time. */
  idleMs: number;
  /** The text so far (finished phrases plus the one being spoken). */
  onText(text: string): void;
  /** Input level, 0..1, about 20 times a second while listening. */
  onLevel(level: number): void;
  onPhase(phase: DictationPhase): void;
}

export interface Dictation {
  /** The final text ("" when nothing was said or it was cancelled). */
  done: Promise<string>;
  /** Stop listening now; what was said is still transcribed. */
  finish(): void;
  /** Stop and throw everything away. */
  cancel(): void;
}

// ── Whisper's hallucinations ──────────────────────────────────────────────────

/** Never something a person dictates to a chat. */
const ALWAYS_NOISE = /amara\.org|subtitles? by|thanks? for watching|please subscribe|like and subscribe|transcri(bed|ption) by|ご視聴|продолжение следует|字幕/i;
/** Real words, but what Whisper says on a breath or a click: dropped when the phrase was that short. */
const SHORT_NOISE = new Set(["thank you", "thank you very much", "thanks", "you", "bye", "bye bye", "uh", "um", "hmm", "so", "oh"]);

export function isHallucination(text: string, voicedMs: number): boolean {
  const plain = text.toLowerCase().replace(/[^\p{L}\p{N}' ]+/gu, " ").replace(/\s+/g, " ").trim();
  if (!plain) return true;
  if (ALWAYS_NOISE.test(text)) return true;
  return voicedMs < 1500 && SHORT_NOISE.has(plain);
}

// ── Audio helpers ─────────────────────────────────────────────────────────────

function rms(frame: Float32Array): number {
  let sum = 0;
  for (let i = 0; i < frame.length; i++) sum += frame[i] * frame[i];
  return Math.sqrt(sum / frame.length);
}

/** Frames at `rate` → one 16 kHz, 16-bit mono WAV. */
export function wav(frames: Float32Array[], rate: number): Blob {
  const total = frames.reduce((n, f) => n + f.length, 0);
  const all = new Float32Array(total);
  let at = 0;
  for (const f of frames) {
    all.set(f, at);
    at += f.length;
  }
  const step = rate / RATE;
  const n = Math.floor(total / step);
  const view = new DataView(new ArrayBuffer(44 + n * 2));
  const str = (o: number, s: string) => [...s].forEach((c, i) => view.setUint8(o + i, c.charCodeAt(0)));
  str(0, "RIFF");
  view.setUint32(4, 36 + n * 2, true);
  str(8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, RATE, true);
  view.setUint32(28, RATE * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  str(36, "data");
  view.setUint32(40, n * 2, true);
  for (let i = 0; i < n; i++) {
    // Average the source samples this output sample covers (a crude low-pass).
    const from = Math.floor(i * step);
    const to = Math.max(from + 1, Math.floor((i + 1) * step));
    let s = 0;
    for (let j = from; j < to; j++) s += all[j];
    const v = Math.max(-1, Math.min(1, s / (to - from)));
    view.setInt16(44 + i * 2, v < 0 ? v * 0x8000 : v * 0x7fff, true);
  }
  return new Blob([view], { type: "audio/wav" });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ── Dictation ─────────────────────────────────────────────────────────────────

/** Opens the mic and starts listening. Rejects if there is no usable mic. */
export async function startDictation(opts: DictationOptions): Promise<Dictation> {
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
  });
  const ctx = new AudioContext();
  const source = ctx.createMediaStreamSource(stream);
  // ponytail: ScriptProcessorNode is deprecated but runs in WebView2 and
  // WebKitGTK alike with no extra module file; an AudioWorklet (a separate
  // script, as the CSP forbids blob: modules) if it ever goes away.
  const proc = ctx.createScriptProcessor(2048, 1, 1);
  const frameMs = (2048 / ctx.sampleRate) * 1000;
  // Chromium only runs a processor that reaches the speakers: through a muted
  // gain, so the mic is never played back.
  const mute = ctx.createGain();
  mute.gain.value = 0;

  let resolve!: (text: string) => void;
  let reject!: (err: unknown) => void;
  const done = new Promise<string>((res, rej) => {
    resolve = res;
    reject = rej;
  });

  let state: "listening" | "transcribing" | "over" = "listening";
  const committed: string[] = [];
  let interim = "";
  let interimOf = -1; // the phrase that re-read was of
  const show = () => opts.onText([...committed, interim].filter(Boolean).join(" "));

  // Voice activity.
  let floor = -1; // the room's noise, learnt as it goes
  let spokeAt = 0; // ms of the last speech frame
  let heard = false; // a phrase long enough to transcribe has been spoken
  let clock = 0; // ms of audio heard
  let pre: Float32Array[] = [];
  let phrase: Float32Array[] | null = null;
  let phraseId = 0;
  let phraseMs = 0;
  let voicedMs = 0;
  let pauseMs = 0;
  let lastInterim = 0;

  // Requests: one at a time, in order, within the minute budget.
  const sentAt: number[] = [];
  const used = () => {
    const now = Date.now();
    while (sentAt.length && now - sentAt[0] > 60_000) sentAt.shift();
    return sentAt.length;
  };
  let busy = 0;
  let queue: Promise<void> = Promise.resolve();

  const stopAudio = () => {
    proc.onaudioprocess = null;
    source.disconnect();
    proc.disconnect();
    mute.disconnect();
    stream.getTracks().forEach((t) => t.stop());
    void ctx.close();
  };

  const over = () => state === "over"; // read after awaits, where TS can't narrow

  const fail = (err: unknown) => {
    if (state === "over") return;
    if (state === "listening") stopAudio();
    state = "over";
    reject(err);
  };

  /** A finished phrase: transcribed in turn, its text kept unless it's noise. */
  const commit = (frames: Float32Array[], voiced: number) => {
    const id = phraseId;
    const audio = wav(frames, ctx.sampleRate);
    queue = queue.then(async () => {
      if (over()) return;
      while (used() >= PER_MINUTE && !over()) await sleep(500);
      if (over()) return;
      sentAt.push(Date.now());
      busy++;
      try {
        const text = (await Bridge.transcribe(audio)).trim();
        if (over()) return;
        if (text && !isHallucination(text, voiced)) committed.push(text);
      } catch (err) {
        fail(err);
        return;
      } finally {
        busy--;
      }
      if (interimOf === id) interim = ""; // the early read it replaces
      show();
    });
  };

  /** The phrase still being spoken, read early so words show before the pause. */
  const peek = () => {
    if (!phrase || busy || used() >= INTERIM_PER_MINUTE) return;
    const id = phraseId;
    const voiced = voicedMs;
    sentAt.push(Date.now());
    busy++;
    Bridge.transcribe(wav(phrase, ctx.sampleRate))
      .then((text) => {
        // Only while that phrase is still the one being spoken.
        if (state === "listening" && phraseId === id && phrase && !isHallucination(text, voiced)) {
          interim = text.trim();
          interimOf = id;
          show();
        }
      })
      .catch(() => {}) // the finished phrase reports any real problem
      .finally(() => busy--);
  };

  const closePhrase = () => {
    if (!phrase) return;
    if (voicedMs >= MIN_VOICED_MS) commit(phrase, voicedMs);
    phrase = null;
    phraseId++;
  };

  /** Stop listening; the last phrase is still transcribed, then the text is final. */
  const finish = () => {
    if (state !== "listening") return;
    state = "transcribing";
    stopAudio();
    closePhrase();
    opts.onLevel(0);
    opts.onPhase("transcribing");
    void queue.then(() => {
      if (state === "over") return;
      state = "over";
      resolve(committed.join(" ").trim());
    });
  };

  proc.onaudioprocess = (e) => {
    if (state !== "listening") return;
    const frame = new Float32Array(e.inputBuffer.getChannelData(0));
    const level = rms(frame);
    clock += frameMs;
    opts.onLevel(Math.min(1, Math.sqrt(level / 0.12)));

    if (floor < 0) floor = level;
    const speech = level > Math.max(MIN_SPEECH_RMS, floor * OVER_FLOOR);
    // The floor follows the room down quickly and up slowly, so speech
    // doesn't become the new "silence".
    floor = speech ? floor : level < floor ? floor * 0.8 + level * 0.2 : floor * 0.98 + level * 0.02;

    if (speech) {
      spokeAt = clock;
      if (!phrase) {
        phrase = pre;
        phraseMs = pre.length * frameMs;
        voicedMs = 0;
        lastInterim = clock;
        pre = [];
      }
    }

    if (phrase) {
      phrase.push(frame);
      phraseMs += frameMs;
      if (speech) {
        voicedMs += frameMs;
        pauseMs = 0;
        heard ||= voicedMs >= MIN_VOICED_MS;
      } else {
        pauseMs += frameMs;
      }
      if (pauseMs >= PHRASE_PAUSE_MS || phraseMs >= MAX_PHRASE_MS) {
        closePhrase();
      } else if (clock - lastInterim >= INTERIM_EVERY_MS && voicedMs >= MIN_VOICED_MS) {
        lastInterim = clock;
        peek();
      }
    } else {
      pre.push(frame);
      if (pre.length * frameMs > PRE_ROLL_MS) pre.shift();
    }

    // Done once speech is followed by silence; never started: give up.
    if (heard ? clock - spokeAt >= END_SILENCE_MS : clock >= opts.idleMs && !phrase) finish();
    else if (clock >= MAX_TOTAL_MS) finish();
  };

  source.connect(proc);
  proc.connect(mute).connect(ctx.destination);
  opts.onPhase("listening");

  return {
    done,
    finish,
    cancel() {
      if (state === "over") return;
      if (state === "listening") stopAudio();
      state = "over";
      resolve("");
    },
  };
}

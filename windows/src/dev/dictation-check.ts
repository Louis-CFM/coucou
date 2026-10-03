// Dev-only self-check for the chat mic's voice detection
// (npm run dev → /dictation-check.html; the page title becomes PASS or FAIL: …).
// A synthetic microphone plays noise bursts ("speech") and silence; the
// speech-to-text call is stubbed, so no key and no network are needed.

import { Bridge } from "../core/bridge";
import { isHallucination, startDictation } from "../views/dictation";

type Burst = [startS: number, endS: number];

/** A fake getUserMedia: syllable-like noise during each burst, silence elsewhere. */
function fakeMic(bursts: Burst[]) {
  navigator.mediaDevices.getUserMedia = async () => {
    const ctx = new AudioContext();
    const noise = ctx.createBuffer(1, ctx.sampleRate * 2, ctx.sampleRate);
    const d = noise.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = (Math.random() * 2 - 1) * (0.6 + 0.4 * Math.sin((i / ctx.sampleRate) * 2 * Math.PI * 4));
    const src = ctx.createBufferSource();
    src.buffer = noise;
    src.loop = true;
    const gain = ctx.createGain();
    gain.gain.value = 0;
    const t0 = ctx.currentTime + 0.05;
    for (const [a, b] of bursts) {
      gain.gain.setValueAtTime(0.3, t0 + a);
      gain.gain.setValueAtTime(0, t0 + b);
    }
    const dest = ctx.createMediaStreamDestination();
    src.connect(gain).connect(dest);
    src.start();
    return dest.stream;
  };
}

/** RMS of a 16-bit WAV's samples, and its length in seconds. */
async function measure(blob: Blob): Promise<[number, number]> {
  const pcm = new Int16Array((await blob.arrayBuffer()).slice(44));
  let sum = 0;
  for (const v of pcm) sum += (v / 32768) ** 2;
  return [Math.sqrt(sum / Math.max(1, pcm.length)), pcm.length / 16000];
}

async function scenario(bursts: Burst[], idleMs: number, reply: (seconds: number) => string) {
  fakeMic(bursts);
  const sent: [number, number][] = [];
  Bridge.transcribe = async (blob: Blob) => {
    const m = await measure(blob);
    sent.push(m);
    return reply(m[1]);
  };
  const t = performance.now();
  const d = await startDictation({ idleMs, onText() {}, onLevel() {}, onPhase() {} });
  const text = await d.done; // never finished by hand: it must stop on its own
  return { text, sent, seconds: (performance.now() - t) / 1000 };
}

async function run(): Promise<string[]> {
  const fails: string[] = [];
  const check = (name: string, ok: boolean, detail = "") => ok || fails.push(`${name} ${detail}`);

  check("hallucination: short thank you", isHallucination("Thank you.", 400));
  check("hallucination: long thank you is real", !isHallucination("Thank you.", 3000));
  check("hallucination: thanks for watching", isHallucination("Thanks for watching!", 5000));
  check("hallucination: amara", isHallucination("Subtitles by the Amara.org community", 5000));
  check("hallucination: punctuation only", isHallucination(" . ", 5000));
  check("hallucination: real prompt kept", !isHallucination("Fix the failing test in parser.rs", 900));

  // Two phrases with a pause between, then silence: two finals, sent alone.
  const a = await scenario([[0.8, 2.6], [3.6, 5.0]], 8000, (s) => (s > 1 ? "phrase" : "x"));
  const finals = a.text.split(" ").filter((w) => w === "phrase").length;
  check("two phrases transcribed", finals === 2, JSON.stringify(a));
  check("stops by itself after speech", a.seconds < 5.0 + 1.6 + 2.5, `${a.seconds.toFixed(1)}s`);
  check("no silent audio sent", a.sent.every(([rms]) => rms > 0.02), JSON.stringify(a.sent));
  check("within the request budget", a.sent.length <= 6, `${a.sent.length} requests`);

  // Nobody speaks: gives up after idleMs, sends nothing.
  const b = await scenario([], 1500, () => "Thank you.");
  check("silence: nothing sent", b.sent.length === 0, JSON.stringify(b));
  check("silence: empty text", b.text === "");
  check("silence: stops after idle", b.seconds < 3, `${b.seconds.toFixed(1)}s`);

  // A short click/breath Whisper turns into "Thank you.": dropped.
  const c = await scenario([[0.5, 0.85]], 4000, () => "Thank you.");
  check("noise burst: no text", c.text === "", JSON.stringify(c));

  return fails;
}

document.title = "running";
void run().then(
  (fails) => {
    document.title = fails.length ? `FAIL: ${fails.join(" | ")}` : "PASS (dictation)";
  },
  (err) => {
    document.title = `FAIL: ${err}`;
  },
);

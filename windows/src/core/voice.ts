// Voice input: record with MediaRecorder, hand the bytes to Rust, get text.
// The recorder and the error wording live here so the chat bar, the quick
// chat window and the quick task prompt behave the same.

import { Bridge } from "./bridge";

/** Auto-stop, so a forgotten mic never records for ever. */
export const MAX_RECORDING_MS = 60_000;

export const MIC_SETTINGS_HINT = "Microphone is off: Windows Settings → Privacy & security → Microphone.";
export const DICTATE_HINT = "Press Win+H to dictate instead.";

export type VoiceState = "idle" | "recording" | "transcribing";

export interface VoiceProblem {
  message: string;
  /** Show the "Open microphone settings" button. */
  micSettings: boolean;
}

/** getUserMedia / MediaRecorder failure → what the user should do. */
export function micErrorProblem(err: unknown): VoiceProblem {
  const name = (err as { name?: string } | null)?.name ?? "";
  if (name === "NotAllowedError" || name === "SecurityError" || name === "PermissionDeniedError") {
    return { message: `${MIC_SETTINGS_HINT} ${DICTATE_HINT}`, micSettings: true };
  }
  if (name === "NotFoundError" || name === "DevicesNotFoundError" || name === "OverconstrainedError") {
    return { message: `No microphone found (on Remote Desktop, allow audio recording in the connection). ${DICTATE_HINT}`, micSettings: true };
  }
  if (name === "NotReadableError" || name === "AbortError") {
    return { message: `The microphone is busy or could not start. ${DICTATE_HINT}`, micSettings: false };
  }
  const text = String((err as Error)?.message ?? err ?? "").replace(/^Error:\s*/, "");
  return { message: `${text || "Recording failed."} ${DICTATE_HINT}`, micSettings: false };
}

/** Transcription failure (Rust already words 9router errors) + the fallback. */
export function transcribeProblem(err: unknown): VoiceProblem {
  const text = String(err ?? "").replace(/^Error:\s*/, "").trim();
  return { message: `${text || "Transcription failed."} ${DICTATE_HINT}`, micSettings: false };
}

export function pickMimeType(isSupported: (t: string) => boolean): string {
  for (const t of ["audio/webm;codecs=opus", "audio/webm", "audio/ogg;codecs=opus"]) {
    if (isSupported(t)) return t;
  }
  return "";
}

export interface VoiceCallbacks {
  onState(state: VoiceState): void;
  onText(text: string): void;
  onProblem(problem: VoiceProblem): void;
}

/** One recorder per text field. toggle(): idle → recording → transcribing → idle. */
export class VoiceRecorder {
  state: VoiceState = "idle";
  private recorder: MediaRecorder | null = null;
  private stream: MediaStream | null = null;
  private chunks: Blob[] = [];
  private timer: number | null = null;

  constructor(private cb: VoiceCallbacks) {}

  toggle() {
    if (this.state === "idle") void this.start();
    else if (this.state === "recording") this.stop();
  }

  private isRecording(): boolean {
    return this.state === "recording";
  }

  private set(state: VoiceState) {
    this.state = state;
    this.cb.onState(state);
  }

  async start() {
    if (this.state !== "idle") return;
    const status = await Bridge.microphoneStatus();
    if (status?.blocked) {
      this.cb.onProblem({ message: `${status.message} ${DICTATE_HINT}`, micSettings: true });
      return;
    }
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
      this.cb.onProblem({ message: `Recording is not available here. ${DICTATE_HINT}`, micSettings: false });
      return;
    }
    this.set("recording");
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (err) {
      this.set("idle");
      this.cb.onProblem(micErrorProblem(err));
      return;
    }
    // cancel() may have run while the permission was being asked.
    if (!this.isRecording()) {
      this.release();
      return;
    }
    const mimeType = pickMimeType((t) => MediaRecorder.isTypeSupported(t));
    let rec: MediaRecorder;
    try {
      rec = new MediaRecorder(this.stream, mimeType ? { mimeType } : undefined);
    } catch (err) {
      this.release();
      this.set("idle");
      this.cb.onProblem(micErrorProblem(err));
      return;
    }
    this.recorder = rec;
    this.chunks = [];
    rec.ondataavailable = (e) => {
      if (e.data.size > 0) this.chunks.push(e.data);
    };
    rec.onstop = () => void this.finish(rec.mimeType || mimeType || "audio/webm");
    rec.start();
    this.timer = window.setTimeout(() => this.stop(), MAX_RECORDING_MS);
  }

  stop() {
    if (this.state !== "recording") return;
    if (this.timer != null) window.clearTimeout(this.timer);
    this.timer = null;
    if (this.recorder && this.recorder.state !== "inactive") {
      this.set("transcribing");
      this.recorder.stop();
    } else {
      this.release();
      this.set("idle");
    }
  }

  /** Throws away a recording in progress (window hidden, view left). */
  cancel() {
    if (this.timer != null) window.clearTimeout(this.timer);
    this.timer = null;
    if (this.recorder) {
      this.recorder.onstop = null;
      if (this.recorder.state !== "inactive") this.recorder.stop();
    }
    this.recorder = null;
    this.release();
    if (this.state !== "idle") this.set("idle");
  }

  private release() {
    for (const t of this.stream?.getTracks() ?? []) t.stop();
    this.stream = null;
  }

  private async finish(mime: string) {
    this.release();
    this.recorder = null;
    const blob = new Blob(this.chunks, { type: mime });
    this.chunks = [];
    if (blob.size === 0) {
      this.set("idle");
      this.cb.onProblem({ message: `Nothing was recorded. ${DICTATE_HINT}`, micSettings: false });
      return;
    }
    try {
      const text = await Bridge.voiceTranscribe(await blob.arrayBuffer(), mime);
      this.set("idle");
      if (text.trim()) this.cb.onText(text.trim());
      else this.cb.onProblem({ message: `No speech was heard. ${DICTATE_HINT}`, micSettings: false });
    } catch (err) {
      this.set("idle");
      this.cb.onProblem(transcribeProblem(err));
    }
  }
}

/** Inserts `text` at the caret (or replaces the selection), with spacing. */
export function insertText(value: string, start: number, end: number, text: string): { value: string; caret: number } {
  const before = value.slice(0, start);
  const after = value.slice(end);
  const lead = before && !/\s$/.test(before) ? " " : "";
  const trail = after && !/^\s/.test(after) ? " " : "";
  const next = `${before}${lead}${text}${trail}${after}`;
  return { value: next, caret: before.length + lead.length + text.length };
}

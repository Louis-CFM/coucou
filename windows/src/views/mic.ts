// Mic button + the line under it that explains what went wrong. Used by the
// island chat bar, the quick chat window and the task prompt.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { VoiceRecorder, type VoiceProblem, type VoiceState } from "../core/voice";

export interface MicControl {
  button: HTMLButtonElement;
  /** Holds the last problem; empty (and hidden by CSS) otherwise. */
  note: HTMLElement;
  recorder: VoiceRecorder;
  set disabled(v: boolean);
  clearNote(): void;
}

const TITLES: Record<VoiceState, string> = {
  idle: "Speak (click again to stop)",
  recording: "Stop and use what I said",
  transcribing: "Transcribing…",
};

export function micControl(onText: (text: string) => void, onProblem?: (p: VoiceProblem) => void): MicControl {
  const button = h("button", { type: "button", class: "mic-btn", title: TITLES.idle, "aria-label": "Voice input" },
    svg(ICONS.mic, 13)) as HTMLButtonElement;
  const note = h("div", { class: "voice-note", role: "status", "aria-live": "polite" });
  let disabled = false;

  function showProblem(p: VoiceProblem) {
    clear(note);
    note.append(h("span", { text: p.message }));
    if (p.micSettings) {
      note.append(h("button", {
        type: "button",
        class: "link-btn voice-settings",
        text: "Open microphone settings",
        onclick: () => void Bridge.openMicrophoneSettings(),
      }));
    }
    onProblem?.(p);
  }

  const recorder = new VoiceRecorder({
    onState(state) {
      button.classList.toggle("recording", state === "recording");
      button.classList.toggle("busy", state === "transcribing");
      button.title = TITLES[state];
      button.setAttribute("aria-pressed", String(state === "recording"));
      button.disabled = disabled || state === "transcribing";
      if (state === "recording") {
        clear(note);
        Sound.play("peek");
      }
    },
    onText(text) {
      clear(note);
      onText(text);
    },
    onProblem(p) {
      Sound.play("error");
      showProblem(p);
    },
  });

  button.addEventListener("mousedown", (e) => e.preventDefault());
  button.addEventListener("click", (e) => {
    e.stopPropagation();
    recorder.toggle();
  });

  return {
    button,
    note,
    recorder,
    set disabled(v: boolean) {
      disabled = v;
      button.disabled = v || recorder.state === "transcribing";
      if (v && recorder.state === "recording") recorder.cancel();
    },
    clearNote() {
      clear(note);
    },
  };
}

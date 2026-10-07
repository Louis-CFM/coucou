// Robot panel — tell the background robot what to do in the hidden browser,
// watch it (status + a read-only screenshot every ~1.5 s), stop it. Rust does
// the work (src-tauri/src/robot.rs); approvals come up as island cards.

import { h, clear } from "./dom";
import { Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import { MAX_ROBOT_TASK, robotBusy, robotStatusLine } from "../core/robot";
import { insertText } from "../core/voice";
import { micControl } from "./mic";
import type { ViewHost } from "./views";

const PREVIEW_MS = 1500;

export interface RobotHost extends ViewHost {
  cancelVoice(): void;
}

export function buildRobot(onCancel: () => void): RobotHost {
  let error: string | null = null;
  let starting = false;
  let previewTimer: number | null = null;
  let previewBusy = false;
  let previewRun = -1;

  const task = h("textarea", {
    class: "task-input task-prompt robot-task",
    placeholder: "e.g. Open Gemini, make an image of a cat astronaut and download it",
    spellcheck: "false",
    maxlength: String(MAX_ROBOT_TASK),
    "aria-label": "Robot task",
  }) as HTMLTextAreaElement;
  const mic = micControl((text) => {
    const at = insertText(task.value, task.selectionStart ?? task.value.length, task.selectionEnd ?? task.value.length, text);
    task.value = at.value;
    error = null;
    render();
    task.focus();
    task.setSelectionRange(at.caret, at.caret);
  }, () => task.focus());
  mic.button.classList.add("task-mic");

  const note = h("div", { class: "task-note", role: "status", "aria-live": "polite" });
  const files = h("div", { class: "robot-files" });
  const shot = h("img", { class: "robot-shot", alt: "Hidden browser" }) as HTMLImageElement;
  const shotEmpty = h("div", { class: "robot-shot-empty", text: "Preview shows while the robot works." });
  const preview = h("div", { class: "robot-preview", title: "Hidden browser, read-only" }, shot, shotEmpty);
  const stop = h("button", { class: "btn secondary", type: "button", text: "Stop", onclick: () => void doStop() }) as HTMLButtonElement;
  const run = h("button", { class: "btn primary", type: "button", onclick: () => void doRun() },
    h("span", { text: "Run" }), h("span", { class: "kbd", text: "Ctrl↵" })) as HTMLButtonElement;

  task.addEventListener("input", () => {
    error = null;
    render();
  });

  const left = h("div", { class: "robot-left" },
    h("div", { class: "task-prompt-wrap" }, task, mic.button),
    mic.note,
    files,
    h("div", { class: "task-row" }, note, stop, run),
  );
  const body = h("div", { class: "task-body robot-body" }, left, preview);
  const el = h("div", { class: "view" }, h("div", { class: "card wash task-card" }, body));
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(56,189,248,0.32)");

  el.addEventListener("keydown", (e) => {
    const k = e as KeyboardEvent;
    if (k.key === "Escape") {
      k.preventDefault();
      k.stopPropagation();
      onCancel();
    } else if (k.key === "Enter" && k.ctrlKey) {
      k.preventDefault();
      k.stopPropagation();
      void doRun();
    } else {
      k.stopPropagation();
    }
  });

  async function doRun() {
    const text = task.value.trim();
    if (!text || starting || robotBusy(State.robot)) return;
    starting = true;
    error = null;
    Sound.play("send");
    render();
    try {
      State.robot = await Bridge.robotStart(text);
      task.value = "";
    } catch (err) {
      error = String(err).replace(/^Error:\s*/, "");
      Sound.play("error");
    } finally {
      starting = false;
      State.notify();
      render();
    }
  }

  async function doStop() {
    Sound.play("blip");
    const s = await Bridge.robotStop();
    if (s) State.robot = s;
    State.notify();
  }

  async function refreshPreview() {
    if (previewBusy) return;
    previewBusy = true;
    try {
      const url = await Bridge.robotPreview();
      if (url && url.startsWith("data:image/jpeg;base64,")) {
        shot.src = url;
        previewRun = State.robot.runId;
      }
    } catch {
      // Browser not up yet: keep the last frame.
    } finally {
      previewBusy = false;
      render();
    }
  }

  function visible(): boolean {
    return State.mode === "expanded" && State.view === "robot" && !document.hidden;
  }

  /** Polls only while the panel is on screen and a task runs. */
  function syncPreviewTimer() {
    const want = visible() && robotBusy(State.robot);
    if (want && previewTimer == null) {
      void refreshPreview();
      previewTimer = window.setInterval(() => {
        if (!visible() || !robotBusy(State.robot)) {
          window.clearInterval(previewTimer!);
          previewTimer = null;
          return;
        }
        void refreshPreview();
      }, PREVIEW_MS);
    }
  }

  function render() {
    const s = State.robot;
    const busy = robotBusy(s) || starting;
    task.disabled = busy;
    mic.disabled = busy;
    run.toggleAttribute("disabled", busy || !task.value.trim());
    run.title = busy ? "The robot is busy" : "Start the robot";
    stop.style.display = robotBusy(s) ? "" : "none";
    const line = error ? { kind: "error" as const, text: error } : starting ? { kind: "ok" as const, text: "Starting…" } : robotStatusLine(s);
    note.className = `task-note${line.kind ? ` ${line.kind}` : ""}`;
    note.textContent = line.text;
    note.title = line.text;
    clear(files);
    if (s.files.length && !busy) {
      files.textContent = `New in Downloads\\Coucou-Robot: ${s.files.join(", ")}`;
      files.title = s.downloads;
    }
    const hasShot = !!shot.getAttribute("src") && (busy || previewRun === s.runId);
    shot.style.display = hasShot ? "" : "none";
    shotEmpty.style.display = hasShot ? "none" : "";
  }

  render();

  return {
    el,
    sync() {
      render();
      syncPreviewTimer();
    },
    focus() {
      if (!task.disabled) task.focus();
    },
    cancelVoice() {
      mic.recorder.cancel();
    },
  };
}

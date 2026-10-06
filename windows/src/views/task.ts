// "+ New task" — start Claude, Codex, Kimi or Hermes in a folder, as a CLI in
// a new terminal or in its desktop app, with a prompt. Rust does the launch
// (src-tauri/src/launch.rs); this view only collects the four fields.

import { h, clear } from "./dom";
import { Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import {
  TASK_AGENTS, MAX_TASK_PROMPT, defaultTaskForm, outcomeNote, rememberTask, savedFolder, selectAgent, selectTarget,
  taskFormProblem,
  type TaskForm, type TaskOutcome, type TaskTarget,
} from "../core/task";
import type { ViewHost } from "./views";
import { micControl } from "./mic";
import { insertText } from "../core/voice";

export interface TaskHost extends ViewHost {
  /** Window hidden or view left: drop a recording in progress. */
  cancelVoice(): void;
}

/** `onStarted` runs after Go went through (the quick window hides itself). */
export function buildTask(
  onCancel: () => void,
  hold: (on: boolean) => void,
  onStarted?: (outcome: TaskOutcome) => void,
): TaskHost {
  let form: TaskForm = defaultTaskForm(State.settings);
  let busy = false;
  let picking = false;
  /** The folder field was edited by hand for the current agent/target. */
  let folderTouched = false;
  let outcome: TaskOutcome | null = null;
  let error: string | null = null;

  const agentButtons = TASK_AGENTS.map((a) =>
    h("button", {
      type: "button",
      text: a.label,
      onclick: () => {
        form = selectAgent(form, State.settings, a.id);
        folderTouched = false;
        clearNote();
        render();
      },
    }),
  );
  const targetButtons = (["cli", "desktop"] as TaskTarget[]).map((t) =>
    h("button", {
      type: "button",
      text: t === "cli" ? "CLI" : "Desktop",
      onclick: () => {
        form = selectTarget(form, State.settings, t);
        folderTouched = false;
        clearNote();
        render();
      },
    }),
  );

  const folder = h("input", {
    type: "text",
    class: "task-input",
    placeholder: "C:\\path\\to\\project",
    spellcheck: "false",
    "aria-label": "Folder",
  }) as HTMLInputElement;
  const browse = h("button", {
    class: "btn secondary task-browse",
    type: "button",
    text: "Browse…",
    title: "Choose the folder",
    onclick: () => void pickFolder(),
  }) as HTMLButtonElement;
  const prompt = h("textarea", {
    class: "task-input task-prompt",
    placeholder: "What should it do?",
    spellcheck: "false",
    maxlength: String(MAX_TASK_PROMPT),
    "aria-label": "Prompt",
  }) as HTMLTextAreaElement;
  // Spoken text only fills the prompt; Go stays a deliberate click.
  const mic = micControl((text) => {
    const at = insertText(prompt.value, prompt.selectionStart ?? prompt.value.length, prompt.selectionEnd ?? prompt.value.length, text);
    form = { ...form, prompt: at.value };
    clearNote();
    render();
    prompt.focus();
    prompt.setSelectionRange(at.caret, at.caret);
  }, () => prompt.focus());
  mic.button.classList.add("task-mic");
  const note = h("div", { class: "task-note", role: "status", "aria-live": "polite" });
  const cancel = h("button", { class: "btn secondary", type: "button", text: "Cancel", onclick: () => onCancel() });
  const go = h("button", { class: "btn primary", type: "button", onclick: () => void submit() },
    h("span", { text: "Go" }), h("span", { class: "kbd", text: "Ctrl↵" }));

  folder.addEventListener("input", () => {
    form = { ...form, folder: folder.value };
    folderTouched = true;
    clearNote();
    render();
  });
  prompt.addEventListener("input", () => {
    form = { ...form, prompt: prompt.value };
    clearNote();
    render();
  });

  const body = h(
    "div",
    { class: "task-body" },
    h("div", { class: "task-row" },
      h("div", { class: "task-seg", role: "group", "aria-label": "Agent" }, ...agentButtons),
      h("div", { class: "grow" }),
      h("div", { class: "task-seg", role: "group", "aria-label": "Where" }, ...targetButtons),
    ),
    h("label", { class: "task-row task-folder" }, h("span", { class: "task-label", text: "Folder" }), folder, browse),
    h("div", { class: "task-prompt-wrap" }, prompt, mic.button),
    mic.note,
    h("div", { class: "task-row" }, note, cancel, go),
  );

  const el = h("div", { class: "view" }, h("div", { class: "card wash task-card" }, body));
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.38)");

  // Escape cancels the form instead of closing the island; Ctrl+Enter is Go.
  el.addEventListener("keydown", (e) => {
    const k = e as KeyboardEvent;
    if (k.key === "Escape") {
      k.preventDefault();
      k.stopPropagation();
      onCancel();
    } else if (k.key === "Enter" && (k.ctrlKey || (k.target === folder && !k.shiftKey))) {
      k.preventDefault();
      k.stopPropagation();
      if (k.target === folder && !k.ctrlKey) prompt.focus();
      else void submit();
    } else {
      k.stopPropagation();
    }
  });

  function clearNote() {
    if (busy) return;
    outcome = null;
    error = null;
  }

  async function pickFolder() {
    if (busy || picking) return;
    picking = true;
    hold(true);
    render();
    try {
      const picked = await Bridge.pickFolder(form.folder);
      if (picked) {
        form = { ...form, folder: picked };
        folderTouched = true;
        clearNote();
      }
    } catch (err) {
      error = String(err).replace(/^Error:\s*/, "");
    } finally {
      picking = false;
      hold(false);
      render();
      (form.folder ? prompt : folder).focus();
    }
  }

  async function submit() {
    if (busy) return;
    const problem = taskFormProblem(form);
    if (problem) {
      error = problem;
      render();
      return;
    }
    busy = true;
    outcome = null;
    error = null;
    Sound.play("send");
    render();
    try {
      outcome = await Bridge.launchTask(form.agent, form.target, form.folder.trim(), form.prompt);
      State.settings = rememberTask(State.settings, form.agent, form.target, form.folder.trim());
      folderTouched = false;
      Sound.play(outcome.status === "started" ? "finish" : "question");
      if (outcome.status === "started") form = { ...form, prompt: "" };
      onStarted?.(outcome);
    } catch (err) {
      error = String(err).replace(/^Error:\s*/, "");
      Sound.play("error");
    } finally {
      busy = false;
      render();
    }
  }

  function render() {
    agentButtons.forEach((b, i) => {
      const on = TASK_AGENTS[i].id === form.agent;
      b.classList.toggle("on", on);
      b.setAttribute("aria-pressed", String(on));
      b.toggleAttribute("disabled", busy);
    });
    targetButtons.forEach((b, i) => {
      const on = (i === 0 ? "cli" : "desktop") === form.target;
      b.classList.toggle("on", on);
      b.setAttribute("aria-pressed", String(on));
      b.toggleAttribute("disabled", busy);
    });
    if (folder.value !== form.folder) folder.value = form.folder;
    if (prompt.value !== form.prompt) prompt.value = form.prompt;
    folder.disabled = busy || picking;
    browse.disabled = busy || picking;
    prompt.disabled = busy;
    mic.disabled = busy;
    const problem = taskFormProblem(form);
    go.toggleAttribute("disabled", busy || problem != null);
    go.title = problem ?? "Start the task";
    const shown = busy ? { kind: "ok" as const, text: "Starting…" } : outcomeNote(outcome, error);
    clear(note);
    note.className = `task-note${shown ? ` ${shown.kind}` : ""}`;
    if (shown) {
      note.textContent = shown.text;
      note.title = shown.text;
    }
  }

  render();

  return {
    el,
    sync() {
      // Pick up the remembered folder once Rust reports it, unless typed over.
      if (busy || picking || folderTouched) return;
      const saved = savedFolder(State.settings, form.agent, form.target);
      if (saved && saved !== form.folder) {
        form = { ...form, folder: saved };
        render();
      }
    },
    focus() {
      if (!busy && !picking && !outcome && !error && !form.prompt) {
        const fresh = defaultTaskForm(State.settings, form.agent);
        form = folderTouched ? { ...fresh, target: form.target, folder: form.folder } : fresh;
        render();
      }
      (form.folder ? prompt : folder).focus();
    },
    cancelVoice() {
      mic.recorder.cancel();
    },
  };
}

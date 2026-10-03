// Claude Code's questions (`AskUserQuestion`), answered from the island.
//
// Same behaviour as the Mac's question view (docs/INTEGRATIONS.md, "Répondre aux
// questions"): one question at a time with a 1/N counter, the options as chips, a
// free "Other…" field, and "Reply in terminal" to let Claude Code ask there instead.
// A single-choice question with nothing else to answer is answered by the click
// itself; multi-select and several questions use a Next / Send button.

import { Bridge } from "../core/bridge";
import { State, type AskAnswers, type AskQuestion } from "../core/state";
import { localized } from "../core/i18n";
import { clear, h } from "./dom";
import type { ViewActions, ViewHost } from "./views";

const MAX_QUESTIONS = 4;

/** `tool_input.questions` as the model: null unless every question can really be asked. */
export function parseQuestions(input: unknown): AskQuestion[] | null {
  const raw = (input as { questions?: unknown } | null)?.questions;
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > MAX_QUESTIONS) return null;
  const questions: AskQuestion[] = [];
  for (const q of raw as Record<string, unknown>[]) {
    if (typeof q?.question !== "string" || !q.question.trim() || !Array.isArray(q.options)) return null;
    const options = (q.options as Record<string, unknown>[]).filter((o) => typeof o?.label === "string" && o.label);
    if (options.length < 2) return null;
    questions.push({
      question: q.question,
      header: typeof q.header === "string" ? q.header : "",
      options: options.map((o) => ({
        label: o.label as string,
        description: typeof o.description === "string" ? o.description : "",
      })),
      multiSelect: q.multiSelect === true,
    });
  }
  // Two questions with the same text would share one answer.
  return new Set(questions.map((q) => q.question)).size === questions.length ? questions : null;
}

const TEXT = {
  en: { asking: "is asking a question", other: "Other…", next: "Next", send: "Send", terminal: "Reply in terminal" },
  de: { asking: "stellt eine Frage", other: "Andere…", next: "Weiter", send: "Senden", terminal: "Im Terminal antworten" },
  fr: { asking: "pose une question", other: "Autre…", next: "Suivant", send: "Envoyer", terminal: "Répondre dans le terminal" },
};

export function buildQuestion(actions: ViewActions): ViewHost {
  const who = h("div", { class: "who-row" });
  const terminal = h("button", { class: "q-terminal", onclick: () => actions.replyInTerminal() });
  const head = h("div", { class: "q-head" }, who, terminal);
  const title = h("div", { class: "q-title" });
  const chips = h("div", { class: "q-chips" });
  const other = h("input", { class: "q-other", spellcheck: "false", autocomplete: "off" }) as HTMLInputElement;
  const go = h("button", { class: "btn primary q-go" });
  const foot = h("div", { class: "q-foot" }, other, go);
  const body = h("div", { class: "stack q-stack" }, head, title, chips, foot);
  const el = h("div", { class: "view" }, h("div", { class: "card wash" }, body));
  el.querySelector<HTMLElement>(".card")!.style.setProperty("--wash", "rgba(34,211,238,0.10)");

  // Where we are in the current request.
  let shown = "";
  let index = 0;
  let answers: AskAnswers = {};
  let picked: string[] = [];

  const current = (): AskQuestion | undefined => State.pendingQuestion?.questions[index];
  const last = () => index === (State.pendingQuestion?.questions.length ?? 1) - 1;
  /** One click is the whole answer: a single question that takes a single choice. */
  const oneClick = () => !current()?.multiSelect && State.pendingQuestion?.questions.length === 1;

  function submit(value: string | string[]) {
    const q = current();
    if (!q || !State.pendingQuestion) return;
    answers = { ...answers, [q.question]: value };
    if (last()) {
      actions.answerQuestion(answers);
    } else {
      index++;
      picked = [];
      render();
      State.notify();
    }
  }

  /** What the Next / Send button would answer with right now (null: nothing chosen). */
  function value(): string | string[] | null {
    const typed = other.value.trim();
    if (current()?.multiSelect) {
      const all = typed ? [...picked, typed] : picked;
      return all.length ? all : null;
    }
    return typed || picked[0] || null;
  }

  function syncGo() {
    const t = localized(TEXT);
    go.textContent = last() ? t.send : t.next;
    (go as HTMLButtonElement).disabled = value() == null;
    go.style.display = oneClick() && !other.value.trim() ? "none" : "";
  }

  function choose(label: string, chip: HTMLElement) {
    if (current()?.multiSelect) {
      picked = picked.includes(label) ? picked.filter((l) => l !== label) : [...picked, label];
    } else if (oneClick()) {
      return submit(label);
    } else {
      picked = [label];
    }
    // Only the look changes; rebuilding the chips between a mouse-down and a
    // mouse-up would swallow the click.
    for (const c of chips.children) c.classList.toggle("on", picked.includes((c as HTMLElement).dataset.label ?? ""));
    chip.blur();
    syncGo();
  }

  function render() {
    const q = current();
    if (!q) return;
    const t = localized(TEXT);
    title.textContent = q.question;
    clear(chips);
    for (const o of q.options) {
      const chip = h("button", { class: "q-chip", title: o.description, text: o.label });
      chip.dataset.label = o.label;
      chip.addEventListener("click", () => choose(o.label, chip));
      chips.append(chip);
    }
    other.value = "";
    other.placeholder = t.other;
    terminal.textContent = t.terminal;
    syncGo();
  }

  other.addEventListener("input", syncGo);
  other.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && value() != null) submit(value()!);
  });
  go.addEventListener("click", () => value() != null && submit(value()!));
  // The island only takes the keyboard when the user clicks into the field: a
  // question must never steal what they are typing in the terminal.
  other.addEventListener("focus", () => void Bridge.focusWindow(true));
  other.addEventListener("blur", () => void Bridge.focusWindow(false));

  return {
    el,
    sync() {
      const req = State.pendingQuestion;
      if (!req) return;
      const t = localized(TEXT);
      clear(who);
      who.append(
        h("span", { class: "dot", style: `width:8px;height:8px;background:${State.focusTask?.color ?? "#fff"}` }),
        h("span", { class: "n", text: State.focusTask?.name ?? "Claude Code" }),
        h("span", { text: t.asking }),
      );
      if (req.questions.length > 1) who.append(h("span", { class: "q-count", text: `${index + 1}/${req.questions.length}` }));
      if (shown !== req.requestId) {
        shown = req.requestId;
        index = 0;
        answers = {};
        picked = [];
        render();
      }
    },
  };
}

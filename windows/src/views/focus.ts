// The focus timer's card (overview left card): the phase and round, the time
// left with a bar that fills as it runs, and Start / Pause, Skip and Reset.
// Same layout as the other integration cards; the rules are in
// src/core/focus.ts, the clock in src/island/focus.ts.

import { h, dot } from "./dom";
import { State } from "../core/state";
import { pillDefinition } from "../core/pills";
import {
  FOCUS_COLOR, FOCUS_ID, Focus, ROUNDS, formatClock, next, pause, progressAt, remainingAt, reset, start,
} from "../core/focus";
import { focusChanged, phaseLabel } from "../island/focus";
import { t } from "../i18n/i18n";

export interface FocusCardHost {
  el: HTMLElement;
  sync(): void;
}

export function buildFocusCard(): FocusCardHost {
  const headDot = dot(FOCUS_COLOR, 7);
  const sub = h("span");
  const time = h("span", { class: "focus-time" });
  const fill = h("i", { class: "focus-fill" });
  const bar = h("div", { class: "focus-bar" }, fill);
  const primary = h("button", { class: "link-btn" });
  const skip = h("button", { class: "link-btn focus-quiet" });
  const resetBtn = h("button", { class: "link-btn focus-quiet" });

  primary.addEventListener("click", () => {
    const now = Date.now();
    Focus.state = Focus.state.running ? pause(Focus.state, now) : start(Focus.state, now);
    focusChanged();
  });
  // Skip: straight to the next phase, without the sound of a phase that ended.
  skip.addEventListener("click", () => {
    Focus.state = next(Focus.state, Date.now());
    focusChanged();
  });
  resetBtn.addEventListener("click", () => {
    Focus.state = reset();
    focusChanged();
  });

  const el = h("div", { class: "int-card focus-card" },
    h("div", { class: "int-head" }, headDot, h("b", { text: pillDefinition(FOCUS_ID)?.name ?? "Focus timer" }), sub),
    h("div", { class: "focus-row" }, time, bar),
    h("div", { class: "int-actions" }, primary, skip, resetBtn),
  );

  return {
    el,
    sync() {
      const s = Focus.state;
      const now = Date.now();
      const color = State.tasks.find((x) => x.id === FOCUS_ID)?.color ?? FOCUS_COLOR;
      headDot.style.background = color;
      fill.style.background = color;
      primary.style.color = `${color}d9`;

      sub.textContent = `${phaseLabel(s.phase)} · ${t("Round {n} of {total}", { n: s.round, total: ROUNDS })}`;
      const clock = formatClock(remainingAt(s, now));
      if (time.textContent !== clock) time.textContent = clock;
      fill.style.width = `${progressAt(s, now) * 100}%`;

      primary.textContent = s.running ? t("Pause") : s.started ? t("Resume") : t("Start");
      skip.textContent = t("Skip");
      resetBtn.textContent = t("Reset");
      resetBtn.style.display = s.started || s.round !== 1 || s.phase !== "focus" ? "" : "none";
    },
  };
}

// Coucoudoro card — work and rest timer in the notch (#1055).
// Redesigned with macOS Liquid Glass theme, Inter tabular numerals,
// clean spacing with Mochi on the left, and smooth barrel roll digit transitions.

import "./coucoudoro.css";
import { h } from "./dom";
import { CoucoudoroController } from "../core/coucoudoro";
import { Sound } from "../core/sound";
import { t } from "../i18n/i18n";

export const COUCOUDORO_ID = "integration_coucoudoro";
export const COUCOUDORO_BLUE = "#0EA5E9";
export const COUCOUDORO_MINT = "#10B981";
export const COUCOUDORO_AMBER = "#F59E0B";

export interface CoucoudoroCard {
  el: HTMLElement;
  sync(): void;
}

interface DigitSlot {
  el: HTMLElement;
  set(val: string, animate?: boolean): void;
}

function createDigitSlot(initialVal: string): DigitSlot {
  const curr = h("span", { class: "cd-curr", text: initialVal });
  const prev = h("span", { class: "cd-prev", text: initialVal });
  prev.style.display = "none";
  const el = h("div", { class: "cd-digit" }, curr, prev);

  let currentVal = initialVal;

  curr.addEventListener("animationend", () => {
    el.classList.remove("roll");
    prev.style.display = "none";
  });

  function set(newVal: string, animate = true) {
    if (newVal === currentVal) return;
    if (!animate) {
      currentVal = newVal;
      curr.textContent = newVal;
      prev.textContent = newVal;
      el.classList.remove("roll");
      prev.style.display = "none";
      return;
    }

    prev.textContent = currentVal;
    prev.style.display = "block";
    curr.textContent = newVal;
    currentVal = newVal;

    el.classList.remove("roll");
    void el.offsetWidth;
    el.classList.add("roll");
  }

  return { el, set };
}

export function buildCoucoudoroCard(): CoucoudoroCard {
  const ctrl = CoucoudoroController.shared;

  // ── Header: Dot + Title (no redundant subtitle label) ──
  const dotEl = h("div", { class: "cd-dot" });
  const title = h("span", { class: "cd-title", text: "Coucoudoro" });
  const head = h("div", { class: "cd-head" },
    h("div", { class: "cd-title-group" }, dotEl, title),
  );

  // ── Animated Tabular Digit Slots (M1, M2, :, S1, S2) ──
  const m1 = createDigitSlot("2");
  const m2 = createDigitSlot("5");
  const colonEl = h("span", { class: "cd-colon", text: ":" });
  const s1 = createDigitSlot("0");
  const s2 = createDigitSlot("0");

  const digitsWrap = h("div", { class: "cd-digits" }, m1.el, m2.el, colonEl, s1.el, s2.el);

  // ── Action Controls (Play / Pause / Stop: Identical 32px x 32px) ──
  const playSvg = `<svg viewBox="0 0 12 14" class="cd-icon" fill="currentColor"><path d="M0.9375 13.2422C1.25 13.2422 1.51562 13.1172 1.82812 12.9375L10.9375 7.67188C11.5859 7.28906 11.8125 7.03906 11.8125 6.625C11.8125 6.21094 11.5859 5.96094 10.9375 5.58594L1.82812 0.3125C1.51562 0.132812 1.25 0.015625 0.9375 0.015625C0.359375 0.015625 0 0.453125 0 1.13281V12.1172C0 12.7969 0.359375 13.2422 0.9375 13.2422Z" /></svg>`;
  const pauseSvg = `<svg viewBox="0 0 10 13" class="cd-icon" fill="currentColor"><path d="M1.03906 12.7266H2.82031C3.5 12.7266 3.85938 12.3672 3.85938 11.6797V1.03906C3.85938 0.328125 3.5 0 2.82031 0H1.03906C0.359375 0 0 0.359375 0 1.03906V11.6797C0 12.3672 0.359375 12.7266 1.03906 12.7266ZM6.71875 12.7266H8.49219C9.17969 12.7266 9.53125 12.3672 9.53125 11.6797V1.03906C9.53125 0.328125 9.17969 0 8.49219 0H6.71875C6.03906 0 5.67969 0.328125 5.67969 1.03906V11.6797C5.67969 12.3672 6.03906 12.7266 6.71875 12.7266Z" /></svg>`;
  const stopSvg = `<svg viewBox="0 0 12 12" class="cd-icon" fill="currentColor"><rect x="1.5" y="1.5" width="9" height="9" rx="2" /></svg>`;

  const playBtn = h("button", {
    class: "cd-btn-play",
    type: "button",
    "aria-label": t("Start"),
  });

  const stopBtn = h("button", {
    class: "cd-btn-stop",
    type: "button",
    "aria-label": t("Stop"),
    title: t("Stop"),
  });
  stopBtn.innerHTML = stopSvg;

  const controls = h("div", { class: "cd-controls" }, playBtn, stopBtn);
  const mainRow = h("div", { class: "cd-main" }, digitsWrap, controls);

  playBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    const snap = ctrl.snapshot;
    if (snap.phase === "idle") {
      ctrl.start();
      Sound.play("work");
    } else if (snap.paused) {
      ctrl.resume();
    } else {
      ctrl.pause();
    }
    sync();
  });

  stopBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    ctrl.stop();
    sync();
  });

  // ── Bottom Progress Bar ──
  const progressFill = h("div", { class: "cd-progress-fill" });
  const progressTrack = h("div", { class: "cd-progress-track" }, progressFill);

  const el = h("div", { class: "coucoudoro-card" }, head, mainRow, progressTrack);

  let initialized = false;

  function sync() {
    const snap = ctrl.snapshot;
    const isPaused = snap.paused;
    const isIdle = snap.phase === "idle";
    const isRest = snap.phase === "rest";

    // ── Phase Dot & Color ──
    dotEl.className = "cd-dot";
    colonEl.className = "cd-colon";

    let themeColor = COUCOUDORO_BLUE;

    if (isIdle) {
      themeColor = COUCOUDORO_BLUE;
    } else if (isPaused) {
      dotEl.classList.add("paused");
      colonEl.classList.add("blink");
      themeColor = COUCOUDORO_AMBER;
    } else if (isRest) {
      dotEl.classList.add("rest");
      themeColor = COUCOUDORO_MINT;
    } else {
      themeColor = COUCOUDORO_BLUE;
    }

    progressFill.style.background = themeColor;

    // ── Update Time & Animated Digit Roll ──
    const remSeconds = Math.max(0, Math.ceil(ctrl.remaining()));
    const m = Math.floor(remSeconds / 60);
    const s = remSeconds % 60;

    const mStr = String(m).padStart(2, "0");
    const sStr = String(s).padStart(2, "0");

    const shouldAnimate = initialized && !isIdle;
    m1.set(mStr[0], shouldAnimate);
    m2.set(mStr[1], shouldAnimate);
    s1.set(sStr[0], shouldAnimate);
    s2.set(sStr[1], shouldAnimate);

    initialized = true;

    // ── Update Progress Fill ──
    const totalSec = isRest ? ctrl.config.rest : ctrl.config.work;
    const progress = totalSec > 0 ? Math.max(0, Math.min(1, remSeconds / totalSec)) : 0;
    progressFill.style.width = `${Math.round(progress * 100)}%`;

    // ── Update Controls ──
    if (isIdle) {
      playBtn.innerHTML = playSvg;
      playBtn.setAttribute("aria-label", t("Start"));
      playBtn.style.background = COUCOUDORO_BLUE;
      stopBtn.style.display = "none";
    } else if (isPaused) {
      playBtn.innerHTML = playSvg;
      playBtn.setAttribute("aria-label", t("Resume"));
      playBtn.style.background = COUCOUDORO_AMBER;
      stopBtn.style.display = "inline-flex";
    } else {
      playBtn.innerHTML = pauseSvg;
      playBtn.setAttribute("aria-label", t("Pause"));
      playBtn.style.background = isRest ? COUCOUDORO_MINT : COUCOUDORO_BLUE;
      stopBtn.style.display = "inline-flex";
    }
  }

  ctrl.subscribe(sync);
  sync();

  return { el, sync };
}

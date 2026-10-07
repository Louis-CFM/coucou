// Shared frame of the two hotkey windows: a draggable title bar with a close
// button, Escape to hide, and the settings kept in step with the island.

import "../style.css";
import "./quick.css";
import { Bridge, onEvent, type QuickLabel } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type Settings } from "../core/state";
import { h, svg } from "../views/dom";
import { ICONS } from "../views/icons";

export interface QuickFrame {
  body: HTMLElement;
  hide(): void;
}

export async function quickFrame(label: QuickLabel, title: string): Promise<QuickFrame> {
  const root = document.getElementById("quick-root")!;
  void Sound.preload();

  const hide = () => void Bridge.quickHide(label);
  const close = h("button", { type: "button", class: "quick-close", title: "Hide (Esc)", "aria-label": "Hide", onclick: hide },
    svg(ICONS.xmark, 11));
  close.addEventListener("mousedown", (e) => e.stopPropagation());
  const bar = h("div", { class: "quick-bar", "data-tauri-drag-region": "" },
    h("span", { class: "quick-title", "data-tauri-drag-region": "", text: title }), close);
  const body = h("div", { class: "quick-body" });
  root.append(h("div", { class: "quick-shell" }, bar, body));

  // Capture phase: views stop Escape from bubbling (it closes the island there).
  window.addEventListener("keydown", (e) => {
    if (e.key !== "Escape" || e.defaultPrevented) return;
    const menuOpen = document.querySelector(".model-menu:not([hidden])");
    if (menuOpen) return;
    e.preventDefault();
    hide();
  }, true);

  const boot = await Bridge.boot();
  if (boot) State.settings = { ...State.settings, ...boot.settings };
  applySound();
  await onEvent<Settings>("settings-changed", (s) => {
    State.settings = { ...State.settings, ...s };
    applySound();
    State.notify();
  });
  return { body, hide };
}

function applySound() {
  Sound.setEnabled(State.settings.soundEnabled);
  Sound.setVolume(State.settings.soundVolume);
}

/** Redraws the active view on the next frame after any state change. */
export function renderLoop(sync: () => void) {
  let queued = false;
  State.subscribe(() => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      sync();
    });
  });
  sync();
}

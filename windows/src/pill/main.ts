// Flow dictation's pill (pill.html). Port of FlowPillView (FlowPill.swift).
//
// What it shows comes whole from Rust in `pill-state` events; the nine dots
// come in `pill-bands` about 30 times a second while you speak. The page tells
// Rust where the pill and its bubble are (`pill_hot`), so the rest of the
// window lets clicks through; it draws only while something moves.

import "./pill.css";
import { Bridge, onEvent } from "../core/bridge";
import { FlowBridge, clock, type PillState } from "../core/flow";
import type { Settings } from "../core/state";
import { BotEngine, hexToRGB } from "../mochi/engine";
import { resolveLanguage, setLanguage, systemLanguages, t } from "../i18n/i18n";
import { HUB_ICONS, keyLabel } from "../hub/ui";

const RESTING_LENGTH = 44;
const RESTING_THICKNESS = 8;
const OPEN_THICKNESS = 34;
const BANDS = 9;

let state: PillState = { phase: "idle", edge: "bottom", key: "right_ctrl", noteStartedAt: null, announcement: null, enabled: false, voice: null };
let platform: "windows" | "linux" = navigator.userAgent.includes("Windows") ? "windows" : "linux";
let hovered = false;
let tooltip: string | null = null;
let unhover: number | null = null;
let visible = false;
const levels = new Array<number>(BANDS).fill(0);
const target = new Array<number>(BANDS).fill(0);

const root = document.getElementById("pill")!;

function svgIcon(name: string): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", HUB_ICONS[name] ?? "");
  svg.append(path);
  return svg;
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls = "", text = ""): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text) e.textContent = text;
  return e;
}

// ── Mochi ─────────────────────────────────────────────────────────────────────

const mochi = new BotEngine();
mochi.isMini = true;
mochi.bodyColor = hexToRGB("#F5F6F8");
mochi.setState("idle", true);
const mochiCanvas = el("canvas");

function mochiSlot(): HTMLElement {
  const slot = el("span", "mochi");
  slot.append(mochiCanvas);
  return slot;
}

// ── Looks ─────────────────────────────────────────────────────────────────────

type Look = "resting" | "toolbar" | "note" | "live" | "handsFree" | "message" | "voice";

function look(): Look {
  switch (state.phase) {
    case "locked":
      return "handsFree";
    case "listening":
    case "thinking":
      return "live";
    case "copied":
    case "failed":
    case "pastedAgain":
      return "message";
    default:
      if (state.voice) return "voice";
      if (state.noteStartedAt) return "note";
      return hovered ? "toolbar" : "resting";
  }
}

const vertical = () => state.edge !== "bottom";

function messageText(): string | null {
  switch (state.phase) {
    case "copied":
      return t("Copied · press Ctrl+V to paste");
    case "failed":
      return t("Microphone unavailable");
    case "pastedAgain":
      return t("Last dictation pasted");
    default:
      return null;
  }
}

function measure(text: string): number {
  const c = document.createElement("canvas").getContext("2d")!;
  c.font = "500 12px system-ui, 'Segoe UI', sans-serif";
  return Math.ceil(c.measureText(text).width);
}

function openLength(l: Look): number {
  const hours = state.noteStartedAt ? Date.now() - state.noteStartedAt >= 3_600_000 : false;
  switch (l) {
    case "toolbar":
      return 150;
    case "note":
      return vertical() ? 128 : hours ? 152 : 136;
    case "handsFree":
      return 158;
    case "message":
      return vertical() ? 76 : measure(messageText() ?? "") + 22 + 9 + 26 + 2;
    case "voice":
      return 118;
    default:
      return 118;
  }
}

function pillButton(icon: string, tip: string, action: () => void, opts: { small?: boolean; filled?: boolean } = {}): HTMLElement {
  const b = el("button", ["pbtn", opts.small ? "small" : "", opts.filled ? "filled" : ""].filter(Boolean).join(" "));
  b.append(svgIcon(icon));
  b.addEventListener("click", (e) => {
    e.stopPropagation();
    action();
  });
  b.addEventListener("pointerenter", () => {
    tooltip = tip;
    render();
  });
  b.addEventListener("pointerleave", () => {
    if (tooltip === tip) {
      tooltip = null;
      render();
    }
  });
  return b;
}

const barsEl = el("span", "bars");
for (let i = 0; i < BANDS; i++) barsEl.append(el("i"));

function noteClock(): HTMLElement {
  const span = el("span", "clock");
  span.dataset.clock = "1";
  span.textContent = clock((Date.now() - (state.noteStartedAt ?? Date.now())) / 1000);
  return span;
}

function content(l: Look): HTMLElement {
  const c = el("div", "content");
  const key = keyLabel(state.key, platform);
  switch (l) {
    case "toolbar": {
      c.style.gap = "4px";
      const m = mochiSlot();
      m.style.margin = vertical() ? "0 0 5px" : "0 5px 0 0";
      c.append(
        m,
        pillButton("mic", t("Dictate · {0}", { 0: key }), () => void FlowBridge.pillAction("dictate")),
        pillButton("record", t("Record a call"), () => void FlowBridge.pillAction("note")),
        pillButton("window", t("Open Coucou"), () => void FlowBridge.pillAction("hub")),
      );
      break;
    }
    case "handsFree":
      c.append(
        pillButton("x", t("Cancel"), () => void FlowBridge.pillAction("cancel"), { small: true }),
        barsEl,
        pillButton("check", t("Paste · or press {0}", { 0: key }), () => void FlowBridge.pillAction("finish"), { small: true, filled: true }),
      );
      break;
    case "message":
      if (vertical()) {
        const icon = el("span");
        icon.append(svgIcon(state.phase === "failed" ? "mic" : "copy"));
        icon.querySelector("svg")!.setAttribute("style", "width:13px;height:13px;fill:none;stroke:#e8e9ec;stroke-width:2");
        c.append(mochiSlot(), icon);
      } else {
        c.append(mochiSlot(), el("span", "message", messageText() ?? ""));
      }
      break;
    case "note": {
      c.style.gap = vertical() ? "6px" : "8px";
      const stop = el("button", "stop");
      stop.title = t("Stop");
      stop.append(el("i"));
      stop.addEventListener("click", (e) => {
        e.stopPropagation();
        void FlowBridge.pillAction("stopNote");
      });
      c.append(mochiSlot(), el("span", "rec"), noteClock(), stop);
      break;
    }
    default:
      c.append(mochiSlot(), barsEl);
  }
  return c;
}

function bubble(): HTMLElement | null {
  const a = state.announcement;
  if (a) {
    const b = el("div", "bubble announce");
    const icon = el("span", "icon");
    const name = { mic: "mic", lock: "lock", clipboard: "copy", download: "download", check: "check", error: "x" }[a.icon] ?? "check";
    icon.append(svgIcon(name));
    icon.style.color = a.tint;
    b.append(icon, el("span", "text", a.text));
    if (a.action) {
      const act = el("button", "act", a.action);
      act.addEventListener("click", () => void FlowBridge.pillAction("announcement", a.id));
      b.append(act);
    }
    const close = el("button", "close");
    close.title = t("Close");
    close.append(svgIcon("x"));
    close.addEventListener("click", () => void FlowBridge.pillAction("dismiss", a.id));
    b.append(close);
    return b;
  }
  const v = state.voice;
  if (v && (v.heard || v.answer || v.phase === "listening")) {
    const b = el("div", "bubble voice");
    if (v.heard) b.append(el("span", "heard", v.heard));
    if (v.answer) b.append(el("span", "answer", v.answer));
    else if (!v.heard) b.append(el("span", "heard", t("Listening…")));
    return b;
  }
  const text = tooltip ?? (vertical() ? messageText() : null);
  return text ? el("div", "bubble", text) : null;
}

// ── Drawing ───────────────────────────────────────────────────────────────────

let capsule: HTMLElement | null = null;
let lastKey = "";

function render() {
  const l = look();
  const open = l !== "resting";
  const length = open ? openLength(l) : RESTING_LENGTH;
  const thickness = open ? OPEN_THICKNESS : RESTING_THICKNESS;
  root.className = `${state.edge}${vertical() ? " vertical" : ""}`;
  const key = `${l}|${state.edge}|${state.phase}|${state.key}|${state.noteStartedAt}|${platform}|${state.voice?.phase ?? ""}`;
  if (!capsule || key !== lastKey) {
    lastKey = key;
    const next = el("div", "capsule");
    next.append(content(l));
    if (capsule) {
      // Keep the size it had, so the new one grows from it.
      next.style.width = capsule.style.width;
      next.style.height = capsule.style.height;
    }
    capsule?.remove();
    capsule = next;
  }
  capsule.classList.toggle("open", open);
  capsule.classList.toggle("handsfree", l === "handsFree");
  requestAnimationFrame(() => {
    if (!capsule) return;
    capsule.style.width = `${vertical() ? thickness : length}px`;
    capsule.style.height = `${vertical() ? length : thickness}px`;
  });
  // Bubble first in the DOM: the flex direction puts it beside the pill.
  for (const old of root.querySelectorAll(".bubble")) old.remove();
  const b = bubble();
  root.replaceChildren(...(b ? [b] : []), capsule);
  mochi.setState(state.phase === "thinking" || state.voice?.phase === "thinking" ? "thinking" : "idle");
  wake();
  // Where the mouse is taken, once the sizes have settled.
  setTimeout(reportHot, 60);
  setTimeout(reportHot, 420);
}

function reportHot() {
  const rects: [number, number, number, number][] = [];
  const W = window.innerWidth;
  const H = window.innerHeight;
  const open = look() !== "resting";
  // The pill: a generous zone around the small resting one, the capsule once open.
  if (state.edge === "bottom") {
    const w = open ? 200 : 96;
    const h = open ? 46 : 26;
    rects.push([(W - w) / 2, H - h, w, h]);
  } else {
    const w = open ? 46 : 26;
    const h = open ? 200 : 96;
    rects.push([state.edge === "left" ? 0 : W - w, (H - h) / 2, w, h]);
  }
  const b = root.querySelector<HTMLElement>(".bubble");
  if (b) {
    const r = b.getBoundingClientRect();
    rects.push([r.left - 6, r.top - 6, r.width + 12, r.height + 12]);
  }
  void FlowBridge.pillHot(rects);
}

// ── Hover ─────────────────────────────────────────────────────────────────────

function setHovered(inside: boolean) {
  if (inside) {
    if (unhover !== null) {
      clearTimeout(unhover);
      unhover = null;
    }
    if (!hovered) {
      hovered = true;
      void FlowBridge.pillHover(true);
      render();
    }
  } else if (hovered && unhover === null) {
    // A short grace, to move from the pill to its bubble.
    unhover = window.setTimeout(() => {
      unhover = null;
      hovered = false;
      tooltip = null;
      void FlowBridge.pillHover(false);
      render();
    }, 250);
  }
}

document.addEventListener("pointermove", (e) => {
  const overPill = capsule?.contains(e.target as Node) || (e.target as HTMLElement)?.closest?.(".bubble");
  const near = capsule ? distanceTo(capsule, e.clientX, e.clientY) < 14 : false;
  setHovered(Boolean(overPill || near));
});
document.addEventListener("pointerleave", () => setHovered(false));

function distanceTo(elm: HTMLElement, x: number, y: number): number {
  const r = elm.getBoundingClientRect();
  const dx = Math.max(r.left - x, 0, x - r.right);
  const dy = Math.max(r.top - y, 0, y - r.bottom);
  return Math.hypot(dx, dy);
}

// ── The animation loop (only while something moves) ───────────────────────────

let frame: number | null = null;
let last = performance.now();

function animating(): boolean {
  return visible && look() !== "resting";
}

/** Where dot `i` goes: the voice, a slow wave while thinking, a lively one while Coucou speaks. */
function dotGoal(now: number, i: number): number {
  if (state.phase === "thinking") return 0.25 + 0.25 * Math.sin(now / 160 - i * 0.7);
  if (state.phase === "listening" || state.phase === "locked") return target[i];
  switch (state.voice?.phase) {
    case "thinking":
      return 0.25 + 0.25 * Math.sin(now / 160 - i * 0.7);
    case "speaking":
      return speaking ? 0.2 + 0.35 * Math.abs(Math.sin(now / 110 + i * 1.3) * Math.sin(now / 270 - i * 0.6)) : 0.05;
    case "listening":
      return 0.08 + 0.08 * Math.sin(now / 400 - i * 0.5);
    default:
      return 0;
  }
}

function tick(now: number) {
  frame = null;
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  const l = look();
  // The dots: follow the voice, or a slow wave while thinking.
  for (let i = 0; i < BANDS; i++) {
    const goal = dotGoal(now, i);
    levels[i] += (goal - levels[i]) * Math.min(1, dt * 14);
    const bar = barsEl.children[i] as HTMLElement;
    const size = 3.4 + 16 * Math.max(0, levels[i]);
    if (vertical()) bar.style.width = `${size}px`;
    else bar.style.height = `${size}px`;
  }
  // Mochi: his eyes wander while you speak; still while only a call shows.
  if (l !== "note" || hovered) {
    mochi.lookX = Math.sin(now / 900) * 0.6;
    mochi.lookY = Math.cos(now / 1300) * 0.3;
    mochi.update(dt);
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const size = 22 / 0.6;
    if (mochiCanvas.width !== Math.round(size * dpr)) {
      mochiCanvas.width = Math.round(size * dpr);
      mochiCanvas.height = Math.round(size * dpr);
    }
    const ctx = mochiCanvas.getContext("2d");
    if (ctx) {
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, size, size);
      mochi.draw(ctx, size, size);
    }
  }
  const c = root.querySelector<HTMLElement>("[data-clock]");
  if (c && state.noteStartedAt) c.textContent = clock((Date.now() - state.noteStartedAt) / 1000);
  if (animating()) {
    // A call alone: one frame a second is enough for its clock.
    if (l === "note" && !hovered) setTimeout(() => wake(), 1000);
    else frame = requestAnimationFrame(tick);
  }
}

function wake() {
  if (frame === null && visible) {
    last = performance.now();
    frame = requestAnimationFrame(tick);
  }
}

// ── « OK Coucou » speaks ──────────────────────────────────────────────────────

interface Say {
  id: number;
  text: string;
  lang: string | null;
  /** ElevenLabs' MP3, base64. */
  audio: string | null;
  gender: "female" | "male";
}

let speaking = false;

/** The system's voice in the answer's language, a woman's or a man's when the system says. */
function systemVoice(lang: string | null, gender: string): SpeechSynthesisVoice | null {
  const voices = window.speechSynthesis?.getVoices() ?? [];
  const want = (lang ?? navigator.language).toLowerCase();
  const short = want.split("-")[0];
  const inLang = voices.filter((v) => v.lang.toLowerCase() === want).concat(voices.filter((v) => v.lang.toLowerCase().split(/[-_]/)[0] === short && v.lang.toLowerCase() !== want));
  const female = /(female|woman|zira|hortense|julie|denise|aria|jenny|samantha|amelie|eloise)/i;
  const male = /(male|man\b|david|paul|guy|henri|claude|mark|thomas)/i;
  const pick = inLang.find((v) => (gender === "male" ? male.test(v.name) && !female.test(v.name) : female.test(v.name)));
  return pick ?? inLang[0] ?? null;
}

async function sayWithSystem(text: string, lang: string | null, gender: string): Promise<void> {
  const synth = window.speechSynthesis;
  if (synth && synth.getVoices().length === 0) {
    await new Promise<void>((r) => {
      synth.addEventListener("voiceschanged", () => r(), { once: true });
      setTimeout(r, 600);
    });
  }
  if (synth && synth.getVoices().length > 0) {
    await new Promise<void>((resolve) => {
      const u = new SpeechSynthesisUtterance(text);
      const voice = systemVoice(lang, gender);
      if (voice) u.voice = voice;
      u.lang = voice?.lang ?? lang ?? navigator.language;
      u.onend = () => resolve();
      u.onerror = () => resolve();
      synth.cancel();
      synth.speak(u);
    });
    return;
  }
  await FlowBridge.sayNative(text, lang);
}

async function sayMp3(base64: string): Promise<boolean> {
  try {
    const audio = new Audio(`data:audio/mpeg;base64,${base64}`);
    await audio.play();
    await new Promise<void>((resolve) => {
      audio.onended = () => resolve();
      audio.onerror = () => resolve();
    });
    return true;
  } catch {
    return false;
  }
}

async function say(s: Say) {
  speaking = true;
  wake();
  try {
    if (!(s.audio && (await sayMp3(s.audio)))) await sayWithSystem(s.text, s.lang, s.gender);
  } finally {
    speaking = false;
    void FlowBridge.voiceDone(s.id);
  }
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function main() {
  const boot = await Bridge.boot();
  setLanguage(resolveLanguage(boot?.settings.language, systemLanguages()));
  const status = await FlowBridge.status();
  if (status) platform = status.platform;
  state = (await FlowBridge.pillState()) ?? state;
  visible = state.enabled || state.noteStartedAt !== null || state.announcement !== null || state.voice !== null;
  render();
  void onEvent<PillState>("pill-state", (s) => {
    state = s;
    if (s.phase === "listening") target.fill(0);
    render();
  });
  void onEvent<number[]>("pill-bands", (bands) => {
    for (let i = 0; i < BANDS; i++) target[i] = bands[i] ?? 0;
    wake();
  });
  void onEvent<boolean>("pill-visible", (v) => {
    visible = v;
    if (!v) {
      hovered = false;
      tooltip = null;
    }
    render();
  });
  // Windows: the cursor poll tells when the pointer is over the pill.
  void onEvent<boolean>("pill-pointer", (inside) => {
    if (!inside) setHovered(false);
  });
  void onEvent<Say>("voice-say", (s) => void say(s));
  void onEvent<Settings>("settings-changed", (s) => {
    setLanguage(resolveLanguage(s.language, systemLanguages()));
    render();
  });
}

void main();

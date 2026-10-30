// The wheel's page (src-tauri/src/wheel): files dropped on the notch's Tools zone
// open it around the pointer. Three rings, Convert · Tools · Actions (keys 1, 2,
// 3 or Tab); the wedge under the pointer lights up, a click (or Enter) runs it.
// The hub shows the file, then the work, then what came of it.

import "./wheel.css";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { Bridge } from "../core/bridge";
import { language, resolveLanguage, setLanguage, systemLanguages, t } from "../i18n/i18n";
import { fileSize, labelPoint, wedgeAt, wedgePath, type Ring } from "./geometry";
import { COMPRESS_LEVELS, EDITOR_TOOLS, iconFor, labelFor, ringLabel, type RingName } from "./labels";

interface FileInfo {
  path: string;
  name: string;
  size: number;
  isDir: boolean;
}
interface Rings {
  kind: string;
  convert: string[];
  tools: string[];
  actions: string[];
}
interface RunResult {
  outputs: string[];
  before: number;
  after: number;
  cancelled: boolean;
}

const NS = "http://www.w3.org/2000/svg";
// The disc: centre (160, 158) in a 320 × 352 window, as wheel/mod.rs shapes it.
const RING: Ring = { cx: 160, cy: 158, inner: 58, outer: 141, gap: 1.6 };
const VIEW_W = 320;
const VIEW_H = 352;
const RING_ORDER: RingName[] = ["convert", "tools", "actions"];

const root = document.getElementById("wheel")!;
let files: FileInfo[] = [];
let rings: Rings = { kind: "other", convert: [], tools: [], actions: [] };
let ring: RingName = "convert";
let hot = -1;
let busy = false;
let closeTimer: number | null = null;
/** "Working… 42%": the line the progress events update. */
let progressLine: HTMLElement | null = null;
/** The choice waiting for FFmpeg's download. */
let pending: { id: string; option: string | null } | null = null;

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, text?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function svgEl(tag: string, attrs: Record<string, string | number> = {}): SVGElement {
  const e = document.createElementNS(NS, tag) as SVGElement;
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v));
  return e;
}

// ── The pieces ──────────────────────────────────────────────────────────────

const svg = svgEl("svg", { class: "ring", viewBox: `0 0 ${VIEW_W} ${VIEW_H}`, width: VIEW_W, height: VIEW_H }) as SVGSVGElement;
// The glass: a top light across the disc, and its rim.
const defs = svgEl("defs");
defs.innerHTML = `
  <linearGradient id="glass" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#fff" stop-opacity="0.34"/>
    <stop offset="0.55" stop-color="#fff" stop-opacity="0.12"/>
    <stop offset="1" stop-color="#fff" stop-opacity="0.06"/>
  </linearGradient>
  <linearGradient id="hot" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ff8a4c"/>
    <stop offset="1" stop-color="#ff4b12"/>
  </linearGradient>
  <radialGradient id="sheen" cx="0.35" cy="0.12" r="0.8">
    <stop offset="0" stop-color="#fff" stop-opacity="0.38"/>
    <stop offset="0.45" stop-color="#fff" stop-opacity="0.05"/>
    <stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </radialGradient>`;
svg.append(defs);
svg.append(svgEl("circle", { class: "backdrop", cx: RING.cx, cy: RING.cy, r: RING.outer + 9 }));
const wedges = svgEl("g") as SVGGElement;
svg.append(wedges);
svg.append(svgEl("circle", { class: "sheen", cx: RING.cx, cy: RING.cy, r: RING.outer + 9 }));

const hub = el("div", "hub");
const hubImg = el("img");
hubImg.alt = "";
const hubGlyph = svgEl("svg", { class: "glyph", viewBox: "0 0 24 24" });
hubGlyph.append(svgEl("path", { d: "M6.5 3.5h7l4 4v13h-11zM13.5 3.5v4h4" }));
const sizePill = el("div", "pill");
const panel = el("div", "hub-panel");
hub.append(hubImg, hubGlyph, sizePill, panel);

const nameTag = el("div", "name-tag");
const ringBar = el("div", "rings");
const ringButtons = RING_ORDER.map((r, i) => {
  const b = el("button");
  b.addEventListener("click", () => switchRing(r));
  b.dataset.ring = r;
  b.dataset.key = String(i + 1);
  return b;
});
ringBar.append(...ringButtons);
// The liquid glass: what is behind the wheel, blurred, cut to the disc and the pill.
const glassDisc = el("div", "glass disc");
const glassBar = el("div", "glass bar");
root.append(glassDisc, glassBar, svg, hub, nameTag, ringBar);

// ── Drawing ─────────────────────────────────────────────────────────────────

function choices(): string[] {
  return rings[ring];
}

function drawWedges() {
  wedges.replaceChildren();
  const list = choices();
  const n = list.length;
  list.forEach((id, i) => {
    const g = svgEl("g", { class: `wedge${ring === "convert" ? "" : " small"}${i === hot ? " hot" : ""}` });
    g.append(svgEl("path", { d: wedgePath(RING, i, n) }));
    const [x, y] = labelPoint(RING, i, n);
    const icon = iconFor(id);
    if (icon && ring !== "convert") {
      const ic = svgEl("path", { class: "icon", d: icon, transform: `translate(${x - 7.5} ${y - 15}) scale(0.62)` });
      g.append(ic);
      const label = svgEl("text", { x, y: y + 8 });
      label.textContent = labelFor(ring, id);
      g.append(label);
    } else {
      const label = svgEl("text", { x, y });
      label.textContent = labelFor(ring, id);
      g.append(label);
    }
    wedges.append(g);
  });
  for (const b of ringButtons) {
    const r = b.dataset.ring as RingName;
    b.replaceChildren(document.createTextNode(ringLabel(r)), Object.assign(el("kbd"), { textContent: b.dataset.key ?? "" }));
    b.classList.toggle("on", r === ring);
    b.disabled = rings[r].length === 0;
  }
}

function setHot(i: number) {
  if (i === hot) return;
  hot = i;
  [...wedges.children].forEach((g, k) => g.classList.toggle("hot", k === hot));
}

function switchRing(r: RingName) {
  if (busy || rings[r].length === 0) return;
  ring = r;
  hot = -1;
  showPanel(null);
  drawWedges();
}

/** The hub's panel: null shows the file again. */
function showPanel(content: HTMLElement[] | null, kind: "" | "error" = "") {
  panel.replaceChildren(...(content ?? []));
  panel.classList.toggle("on", content != null);
  panel.classList.toggle("error", kind === "error");
  svg.classList.toggle("busy", busy);
}

function check(): HTMLElement {
  const c = el("div", "check");
  const s = svgEl("svg", { viewBox: "0 0 24 24" });
  s.append(svgEl("path", { d: "M5.5 12.5l4.2 4.2 8.8-9.2" }));
  c.append(s);
  return c;
}

function button(text: string, onClick: () => void, primary = false): HTMLButtonElement {
  const b = el("button", primary ? "primary" : "", text);
  b.addEventListener("click", (e) => {
    e.stopPropagation();
    onClick();
  });
  return b;
}

function baseName(path: string): string {
  return path.split(/[\\/]/).pop() ?? path;
}

// ── Running a choice ────────────────────────────────────────────────────────

async function choose(i: number) {
  const id = choices()[i];
  if (!id || busy) return;
  if (ring === "tools" && id === "compress") {
    showPanel([
      el("div", "big", t("How small?")),
      ...COMPRESS_LEVELS.map(([level, label], k) => button(label(), () => void run(id, level), k === 1)),
    ]);
    return;
  }
  if (ring === "tools" && EDITOR_TOOLS.has(id)) {
    busy = true;
    showPanel([el("div", "spinner"), el("div", "dim", t("Opening the editor…"))]);
    try {
      await invoke("wheel_editor", { tool: id });
      busy = false;
      close();
    } catch (e) {
      busy = false;
      if (String(e).includes("needs-ffmpeg")) return askFfmpeg(id, null);
      failed(String(e));
    }
    return;
  }
  await run(id, null);
}

async function run(id: string, option: string | null) {
  busy = true;
  cancelClose();
  progressLine = el("div", "dim", t("Working…"));
  showPanel([el("div", "spinner"), progressLine]);
  try {
    const r = await invoke<RunResult>("wheel_run", { ring, id, option });
    busy = false;
    progressLine = null;
    if (r.cancelled) {
      showPanel(null);
      return;
    }
    succeeded(id, r);
  } catch (e) {
    busy = false;
    progressLine = null;
    if (String(e).includes("needs-ffmpeg")) return askFfmpeg(id, option);
    failed(String(e));
  }
}

/** Video and sound need FFmpeg: offered once, then the choice runs. */
function askFfmpeg(id: string, option: string | null) {
  pending = { id, option };
  showPanel([
    el("div", "dim", t("Video and sound need FFmpeg: about 110 MB, downloaded once.")),
    button(t("Download"), () => void getFfmpeg(), true),
    button(t("Back"), () => showPanel(null)),
  ]);
}

async function getFfmpeg() {
  busy = true;
  cancelClose();
  progressLine = el("div", "dim", t("Downloading FFmpeg…"));
  showPanel([el("div", "spinner"), progressLine]);
  try {
    await invoke("wheel_ffmpeg_install");
    busy = false;
    progressLine = null;
    const next = pending;
    pending = null;
    if (next) {
      if (ring === "tools" && EDITOR_TOOLS.has(next.id)) await choose(choices().indexOf(next.id));
      else await run(next.id, next.option);
    } else showPanel(null);
  } catch (e) {
    busy = false;
    progressLine = null;
    failed(String(e));
  }
}

function succeeded(id: string, r: RunResult) {
  const parts: HTMLElement[] = [check()];
  if (ring === "actions" && id === "copy") parts.push(el("div", "big", t("Copied to the clipboard")));
  else if (ring === "actions" && id === "copyPath") parts.push(el("div", "big", t("Path copied")));
  else if (ring === "actions" && id === "move") parts.push(el("div", "big", t("Moved")));
  else if (ring === "actions") parts.push(el("div", "big", t("Done")));
  else {
    parts.push(el("div", "big", r.outputs.length > 1 ? t("{count} files saved", { count: r.outputs.length }) : t("Saved")));
    if (r.outputs.length === 1) parts.push(el("div", "dim", baseName(r.outputs[0])));
    if (r.after > 0 && r.before > 0) {
      parts.push(el("div", "dim", `${fileSize(r.before, language())} → ${fileSize(r.after, language())}`));
    }
  }
  if (r.outputs.length > 0) {
    const first = r.outputs[0];
    parts.push(button(t("Show in Explorer"), () => {
      void invoke("wheel_reveal", { path: first });
      close();
    }, true));
  }
  showPanel(parts);
  scheduleClose(6000);
}

function failed(message: string) {
  if (message.includes("already-small")) {
    showPanel([el("div", "big", t("Already as small as it gets")), button(t("Back"), () => showPanel(null))]);
    return;
  }
  showPanel([el("div", "big", t("Couldn't do it")), el("div", "dim", message.slice(0, 140)), button(t("Back"), () => showPanel(null))], "error");
}

// ── Opening and closing ─────────────────────────────────────────────────────

function cancelClose() {
  if (closeTimer != null) window.clearTimeout(closeTimer);
  closeTimer = null;
}

function scheduleClose(ms: number) {
  cancelClose();
  closeTimer = window.setTimeout(() => {
    if (!root.matches(":hover")) close();
    else scheduleClose(2000);
  }, ms);
}

function close() {
  cancelClose();
  root.classList.remove("on");
  window.setTimeout(() => void invoke("wheel_close"), 140);
}

type Opened = { files: FileInfo[]; rings: Rings; backdrop?: string | null; dark?: boolean };

async function open(payload: Opened) {
  const behind = payload.backdrop ? `url("${payload.backdrop}")` : "none";
  glassDisc.style.backgroundImage = behind;
  glassBar.style.backgroundImage = behind;
  root.classList.toggle("dark", !!payload.dark);
  files = payload.files;
  rings = payload.rings;
  busy = false;
  hot = -1;
  cancelClose();
  ring = RING_ORDER.find((r) => rings[r].length > 0) ?? "actions";
  const first = files[0];
  const total = files.reduce((s, f) => s + f.size, 0);
  sizePill.textContent = files.length > 1 ? `${files.length} · ${fileSize(total, language())}` : fileSize(total, language());
  nameTag.textContent = files.length > 1 ? `${first.name} +${files.length - 1}` : first.name;
  hubImg.style.display = "none";
  hubGlyph.style.display = "";
  showPanel(null);
  drawWedges();
  root.classList.remove("on");
  void root.offsetWidth;
  root.classList.add("on");
  const preview = await invoke<string | null>("wheel_preview", { path: first.path }).catch(() => null);
  if (preview && files[0] === first) {
    hubImg.src = preview;
    hubImg.style.display = "";
    hubGlyph.style.display = "none";
  }
}

// ── Input ───────────────────────────────────────────────────────────────────

function local(e: MouseEvent): [number, number] {
  const r = svg.getBoundingClientRect();
  return [((e.clientX - r.left) / r.width) * VIEW_W, ((e.clientY - r.top) / r.height) * VIEW_H];
}

svg.addEventListener("mousemove", (e) => {
  if (busy) return;
  const [x, y] = local(e);
  setHot(wedgeAt(RING, choices().length, x, y));
});
svg.addEventListener("mouseleave", () => setHot(-1));
svg.addEventListener("click", (e) => {
  const [x, y] = local(e);
  const i = wedgeAt(RING, choices().length, x, y);
  if (i >= 0) void choose(i);
  else if (Math.hypot(x - RING.cx, y - RING.cy) > RING.outer + 9) close();
});
// Outside the circle (the window's transparent corners): close.
document.addEventListener("click", (e) => {
  if (e.target === document.body || e.target === document.documentElement) close();
});

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") return close();
  if (busy) return;
  const n = choices().length;
  if (e.key === "Tab") {
    e.preventDefault();
    const order = RING_ORDER.filter((r) => rings[r].length > 0);
    const next = order[(order.indexOf(ring) + (e.shiftKey ? order.length - 1 : 1)) % order.length];
    if (next) switchRing(next);
  } else if (e.key === "1" || e.key === "2" || e.key === "3") {
    switchRing(RING_ORDER[Number(e.key) - 1]);
  } else if (e.key === "ArrowRight" || e.key === "ArrowDown") {
    setHot(n ? (hot + 1) % n : -1);
  } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
    setHot(n ? (hot - 1 + n) % n : -1);
  } else if (e.key === "Enter" && hot >= 0) {
    void choose(hot);
  }
});

async function main() {
  const boot = await Bridge.boot();
  setLanguage(resolveLanguage(boot?.settings.language, systemLanguages()));
  await listen<Opened>("wheel-open", (e) => void open(e.payload));
  await listen<number>("wheel-progress", (e) => {
    if (!progressLine) return;
    const base = progressLine.dataset.base ?? progressLine.textContent ?? "";
    progressLine.dataset.base = base;
    progressLine.textContent = `${base} ${Math.round(e.payload * 100)}%`;
  });
  // Made just now for this opening: the event may have gone before we listened.
  const current = await invoke<Opened | null>("wheel_current").catch(() => null);
  if (current && !root.classList.contains("on")) void open(current);
  // Clicked elsewhere: the wheel goes away (never in the middle of the work).
  await getCurrentWindow().onFocusChanged(({ payload: focused }) => {
    if (!focused && !busy && root.classList.contains("on")) close();
  });
}

void main();

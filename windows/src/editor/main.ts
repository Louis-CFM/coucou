// The wheel's image editor (src-tauri/src/wheel, wheel_editor): one window, one
// image, one tool — crop, edit, annotate, redact or background. The preview
// fits the window; Save draws everything again at the image's full size.

import "./editor.css";
import { invoke } from "@tauri-apps/api/core";
import { Bridge } from "../core/bridge";
import { resolveLanguage, setLanguage, systemLanguages, t } from "../i18n/i18n";
import { backgroundLayout, cropToAspect, initialCrop, rectFrom, type Rect } from "./geometry";

type Tool = "crop" | "edit" | "annotate" | "redact" | "background";
interface Editing {
  path: string;
  name: string;
  tool: Tool;
  image: string;
}

type MarkTool = "arrow" | "box" | "pen" | "text";
interface Mark {
  tool: MarkTool;
  color: string;
  points: [number, number][];
  text?: string;
}

const canvas = document.getElementById("canvas") as HTMLCanvasElement;
const stage = document.getElementById("stage")!;
const top = document.getElementById("top")!;
const bottom = document.getElementById("bottom")!;
const savedBox = document.getElementById("saved")!;
const ctx = canvas.getContext("2d")!;

let tool: Tool = "crop";
let editing: Editing | null = null;
const img = new Image();
let W = 0;
let H = 0;

// The view: image pixels → canvas pixels.
let scale = 1;
let ox = 0;
let oy = 0;
const dpr = () => window.devicePixelRatio || 1;

// ── Each tool's state ───────────────────────────────────────────────────────

let crop: Rect = { x: 0, y: 0, w: 0, h: 0 };
let aspect: number | null = null;
const adjust = { brightness: 100, contrast: 100, saturation: 100, warmth: 0 };
let marks: Mark[] = [];
let markTool: MarkTool = "arrow";
let markColor = "#ff3b30";
let redactions: Rect[] = [];
let redactMode: "black" | "pixelate" = "black";
const bg = { fill: "tangerine", padding: 0.08, corners: 0.03, shadow: true, aspect: null as number | null };

const FILLS: Record<string, string[]> = {
  tangerine: ["#ffb26b", "#ff5e62"],
  sky: ["#6dd5fa", "#2980b9"],
  violet: ["#a18cd1", "#fbc2eb"],
  mint: ["#43e97b", "#38f9d7"],
  night: ["#232526", "#414345"],
  white: ["#ffffff"],
  cream: ["#f5efe6"],
  black: ["#0e0f11"],
};
const COLORS = ["#ff3b30", "#ff9f0a", "#30d158", "#0a84ff", "#ffffff"];

const strokeWidth = () => Math.max(3, Math.round(Math.max(W, H) / 280));

// ── Helpers ─────────────────────────────────────────────────────────────────

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls = "", text = ""): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text) e.textContent = text;
  return e;
}

function button(text: string, onClick: () => void, cls = ""): HTMLButtonElement {
  const b = el("button", cls, text);
  b.addEventListener("click", onClick);
  return b;
}

/** A row of buttons where one is on. */
function choice<T>(items: [T, string, string?][], current: () => T, set: (v: T) => void): HTMLElement {
  const group = el("div", "group");
  const buttons = items.map(([value, label, title]) => {
    const b = button(label, () => {
      set(value);
      sync();
      render();
    });
    if (title) b.title = title;
    return { value, b };
  });
  const sync = () => buttons.forEach(({ value, b }) => b.classList.toggle("on", value === current()));
  sync();
  group.append(...buttons.map((x) => x.b));
  return group;
}

function slider(label: string, min: number, max: number, value: () => number, set: (v: number) => void, unit = ""): HTMLElement {
  const wrap = el("label", "slider");
  const input = el("input");
  input.type = "range";
  input.min = String(min);
  input.max = String(max);
  input.value = String(value());
  const out = el("output", "", `${value()}${unit}`);
  input.addEventListener("input", () => {
    set(Number(input.value));
    out.textContent = `${input.value}${unit}`;
    render();
  });
  wrap.append(document.createTextNode(label), input, out);
  return wrap;
}

function swatches(colors: string[], current: () => string, set: (c: string) => void, fillOf?: (c: string) => string): HTMLElement {
  const group = el("div", "group");
  const list = colors.map((c) => {
    const b = el("button", "swatch");
    b.style.background = fillOf ? fillOf(c) : c;
    b.addEventListener("click", () => {
      set(c);
      list.forEach((x) => x.classList.toggle("on", x === b));
      render();
    });
    b.classList.toggle("on", c === current());
    return b;
  });
  group.append(...list);
  return group;
}

const css = (stops: string[]) => (stops.length > 1 ? `linear-gradient(135deg, ${stops[0]}, ${stops[1]})` : stops[0]);

// ── Drawing ─────────────────────────────────────────────────────────────────

/** The adjustments as a canvas filter, and the warmth tint after it. */
function applyAdjust(c: CanvasRenderingContext2D, w: number, h: number, draw: () => void) {
  c.save();
  c.filter = `brightness(${adjust.brightness}%) contrast(${adjust.contrast}%) saturate(${adjust.saturation}%)`;
  draw();
  c.restore();
  if (adjust.warmth !== 0) {
    c.save();
    c.globalCompositeOperation = "soft-light";
    const a = (Math.abs(adjust.warmth) / 100) * 0.55;
    c.fillStyle = adjust.warmth > 0 ? `rgba(255,140,30,${a})` : `rgba(30,120,255,${a})`;
    c.fillRect(0, 0, w, h);
    c.restore();
  }
}

function drawArrow(c: CanvasRenderingContext2D, [x0, y0]: [number, number], [x1, y1]: [number, number], sw: number) {
  const ang = Math.atan2(y1 - y0, x1 - x0);
  const head = sw * 4.5;
  c.beginPath();
  c.moveTo(x0, y0);
  c.lineTo(x1 - Math.cos(ang) * head * 0.6, y1 - Math.sin(ang) * head * 0.6);
  c.stroke();
  c.beginPath();
  c.moveTo(x1, y1);
  c.lineTo(x1 - head * Math.cos(ang - 0.45), y1 - head * Math.sin(ang - 0.45));
  c.lineTo(x1 - head * Math.cos(ang + 0.45), y1 - head * Math.sin(ang + 0.45));
  c.closePath();
  c.fill();
}

function drawMarks(c: CanvasRenderingContext2D, list: Mark[]) {
  const sw = strokeWidth();
  for (const m of list) {
    c.save();
    c.strokeStyle = m.color;
    c.fillStyle = m.color;
    c.lineWidth = sw;
    c.lineCap = "round";
    c.lineJoin = "round";
    const [a, b] = [m.points[0], m.points[m.points.length - 1]];
    if (m.tool === "arrow") drawArrow(c, a, b, sw);
    else if (m.tool === "box") {
      const r = rectFrom(a[0], a[1], b[0], b[1]);
      c.strokeRect(r.x, r.y, r.w, r.h);
    } else if (m.tool === "pen") {
      c.beginPath();
      m.points.forEach(([x, y], i) => (i ? c.lineTo(x, y) : c.moveTo(x, y)));
      c.stroke();
    } else if (m.tool === "text" && m.text) {
      const size = Math.max(18, Math.round(Math.max(W, H) / 32));
      c.font = `700 ${size}px system-ui, "Segoe UI", sans-serif`;
      c.textBaseline = "top";
      c.lineWidth = size / 6;
      c.strokeStyle = m.color === "#ffffff" ? "rgba(0,0,0,0.55)" : "rgba(255,255,255,0.85)";
      c.strokeText(m.text, a[0], a[1]);
      c.fillText(m.text, a[0], a[1]);
    }
    c.restore();
  }
}

function drawRedactions(c: CanvasRenderingContext2D, list: Rect[], source: CanvasImageSource) {
  const block = Math.max(8, Math.round(Math.min(W, H) / 55));
  for (const r of list) {
    if (r.w < 1 || r.h < 1) continue;
    if (redactMode === "black") {
      c.fillStyle = "#000";
      c.fillRect(r.x, r.y, r.w, r.h);
      continue;
    }
    const sw = Math.max(1, Math.round(r.w / block));
    const sh = Math.max(1, Math.round(r.h / block));
    const tmp = document.createElement("canvas");
    tmp.width = sw;
    tmp.height = sh;
    const t2 = tmp.getContext("2d")!;
    t2.drawImage(source, r.x, r.y, r.w, r.h, 0, 0, sw, sh);
    c.save();
    c.imageSmoothingEnabled = false;
    c.drawImage(tmp, 0, 0, sw, sh, r.x, r.y, r.w, r.h);
    c.restore();
  }
}

function roundRect(c: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  c.beginPath();
  c.roundRect(x, y, w, h, r);
}

/** The background tool's picture, at `s` times its full size. */
function composeBackground(c: CanvasRenderingContext2D, s: number) {
  const L = backgroundLayout(W, H, bg.padding, bg.aspect);
  const stops = FILLS[bg.fill] ?? FILLS.tangerine;
  const fw = L.width * s;
  const fh = L.height * s;
  if (stops.length > 1) {
    const g = c.createLinearGradient(0, 0, fw, fh);
    g.addColorStop(0, stops[0]);
    g.addColorStop(1, stops[1]);
    c.fillStyle = g;
  } else c.fillStyle = stops[0];
  c.fillRect(0, 0, fw, fh);
  const radius = Math.min(W, H) * bg.corners * s;
  const [x, y, w, h] = [L.x * s, L.y * s, W * s, H * s];
  if (bg.shadow) {
    c.save();
    c.shadowColor = "rgba(0,0,0,0.38)";
    c.shadowBlur = Math.max(W, H) * 0.045 * s;
    c.shadowOffsetY = Math.max(W, H) * 0.015 * s;
    roundRect(c, x, y, w, h, radius);
    c.fillStyle = "#000";
    c.fill();
    c.restore();
  }
  c.save();
  roundRect(c, x, y, w, h, radius);
  c.clip();
  c.drawImage(img, x, y, w, h);
  c.restore();
}

/** The size of what the preview shows, in image pixels. */
function contentSize(): [number, number] {
  if (tool === "background") {
    const L = backgroundLayout(W, H, bg.padding, bg.aspect);
    return [L.width, L.height];
  }
  return [W, H];
}

function fit() {
  const r = stage.getBoundingClientRect();
  canvas.width = Math.round(r.width * dpr());
  canvas.height = Math.round(r.height * dpr());
  const [cw, ch] = contentSize();
  const pad = 28 * dpr();
  scale = Math.min((canvas.width - pad * 2) / cw, (canvas.height - pad * 2) / ch, 4);
  ox = (canvas.width - cw * scale) / 2;
  oy = (canvas.height - ch * scale) / 2;
}

function render() {
  if (!W) return;
  fit();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  if (tool === "background") {
    ctx.setTransform(1, 0, 0, 1, ox, oy);
    composeBackground(ctx, scale);
    return;
  }
  ctx.setTransform(scale, 0, 0, scale, ox, oy);
  if (tool === "edit") applyAdjust(ctx, W, H, () => ctx.drawImage(img, 0, 0, W, H));
  else ctx.drawImage(img, 0, 0, W, H);
  if (tool === "annotate") drawMarks(ctx, drawing ? [...marks, drawing] : marks);
  if (tool === "redact") drawRedactions(ctx, drawingRect ? [...redactions, drawingRect] : redactions, img);
  if (tool === "crop") {
    // Darken outside the frame, then the frame, its thirds and its corners.
    ctx.fillStyle = "rgba(0,0,0,0.55)";
    ctx.beginPath();
    ctx.rect(0, 0, W, H);
    ctx.rect(crop.x, crop.y, crop.w, crop.h);
    ctx.fill("evenodd");
    const lw = 1.5 / scale;
    ctx.strokeStyle = "rgba(255,255,255,0.95)";
    ctx.lineWidth = lw * 1.3;
    ctx.strokeRect(crop.x, crop.y, crop.w, crop.h);
    ctx.strokeStyle = "rgba(255,255,255,0.35)";
    ctx.lineWidth = lw;
    for (const k of [1, 2]) {
      ctx.beginPath();
      ctx.moveTo(crop.x + (crop.w * k) / 3, crop.y);
      ctx.lineTo(crop.x + (crop.w * k) / 3, crop.y + crop.h);
      ctx.moveTo(crop.x, crop.y + (crop.h * k) / 3);
      ctx.lineTo(crop.x + crop.w, crop.y + (crop.h * k) / 3);
      ctx.stroke();
    }
    const hs = 9 / scale;
    ctx.fillStyle = "#fff";
    for (const [hx, hy] of corners(crop)) ctx.fillRect(hx - hs / 2, hy - hs / 2, hs, hs);
  }
}

function corners(r: Rect): [number, number][] {
  return [
    [r.x, r.y],
    [r.x + r.w, r.y],
    [r.x, r.y + r.h],
    [r.x + r.w, r.y + r.h],
  ];
}

/** The finished picture at full size, as a PNG data URL. */
function exportImage(): string {
  const out = document.createElement("canvas");
  const c = out.getContext("2d")!;
  if (tool === "background") {
    const L = backgroundLayout(W, H, bg.padding, bg.aspect);
    out.width = L.width;
    out.height = L.height;
    composeBackground(c, 1);
  } else if (tool === "crop") {
    out.width = Math.max(1, Math.round(crop.w));
    out.height = Math.max(1, Math.round(crop.h));
    c.drawImage(img, crop.x, crop.y, crop.w, crop.h, 0, 0, out.width, out.height);
  } else {
    out.width = W;
    out.height = H;
    if (tool === "edit") applyAdjust(c, W, H, () => c.drawImage(img, 0, 0, W, H));
    else c.drawImage(img, 0, 0, W, H);
    if (tool === "annotate") drawMarks(c, marks);
    if (tool === "redact") drawRedactions(c, redactions, img);
  }
  return out.toDataURL("image/png");
}

// ── Pointer ─────────────────────────────────────────────────────────────────

let drawing: Mark | null = null;
let drawingRect: Rect | null = null;
/** Where a redaction box's drag began. */
let redactStart: [number, number] | null = null;
type CropDrag = { mode: "move" | "new" | "corner"; start: [number, number]; from: Rect; corner?: number };
let cropDrag: CropDrag | null = null;

function toImage(e: PointerEvent): [number, number] {
  const r = canvas.getBoundingClientRect();
  const x = ((e.clientX - r.left) * dpr() - ox) / scale;
  const y = ((e.clientY - r.top) * dpr() - oy) / scale;
  return [Math.max(0, Math.min(W, x)), Math.max(0, Math.min(H, y))];
}

canvas.addEventListener("pointerdown", (e) => {
  if (!W || tool === "edit" || tool === "background") return;
  canvas.setPointerCapture(e.pointerId);
  const p = toImage(e);
  if (tool === "crop") {
    const near = 14 / scale;
    const k = corners(crop).findIndex(([x, y]) => Math.hypot(x - p[0], y - p[1]) < near);
    if (k >= 0) cropDrag = { mode: "corner", start: p, from: { ...crop }, corner: k };
    else if (p[0] > crop.x && p[0] < crop.x + crop.w && p[1] > crop.y && p[1] < crop.y + crop.h)
      cropDrag = { mode: "move", start: p, from: { ...crop } };
    else cropDrag = { mode: "new", start: p, from: { ...crop } };
  } else if (tool === "annotate") {
    if (markTool === "text") return askText(e, p);
    drawing = { tool: markTool, color: markColor, points: [p, p] };
  } else if (tool === "redact") {
    redactStart = p;
    drawingRect = { x: p[0], y: p[1], w: 0, h: 0 };
  }
});

canvas.addEventListener("pointermove", (e) => {
  if (!W) return;
  const p = toImage(e);
  if (cropDrag) {
    const [dx, dy] = [p[0] - cropDrag.start[0], p[1] - cropDrag.start[1]];
    const f = cropDrag.from;
    if (cropDrag.mode === "move") {
      crop = { ...f, x: Math.max(0, Math.min(W - f.w, f.x + dx)), y: Math.max(0, Math.min(H - f.h, f.y + dy)) };
    } else {
      // The corner opposite the one held stays put.
      const anchor: [number, number] =
        cropDrag.mode === "new" ? cropDrag.start : corners(f)[3 - (cropDrag.corner ?? 0)];
      let r = rectFrom(anchor[0], anchor[1], p[0], p[1]);
      if (aspect) {
        const w = Math.max(r.w, r.h * aspect);
        r = { x: p[0] < anchor[0] ? anchor[0] - w : anchor[0], y: p[1] < anchor[1] ? anchor[1] - w / aspect : anchor[1], w, h: w / aspect };
        r = cropToAspect(r, aspect, W, H);
      }
      if (r.w > 4 && r.h > 4) crop = r;
    }
    render();
  } else if (drawing) {
    if (drawing.tool === "pen") drawing.points.push(p);
    else drawing.points[1] = p;
    render();
  } else if (redactStart) {
    drawingRect = rectFrom(redactStart[0], redactStart[1], p[0], p[1]);
    render();
  }
});

canvas.addEventListener("pointerup", () => {
  cropDrag = null;
  if (drawing) {
    const [a, b] = [drawing.points[0], drawing.points[drawing.points.length - 1]];
    if (drawing.tool === "pen" || Math.hypot(b[0] - a[0], b[1] - a[1]) > 3) marks.push(drawing);
    drawing = null;
  }
  if (drawingRect) {
    if (drawingRect.w > 3 && drawingRect.h > 3) redactions.push(drawingRect);
    drawingRect = null;
  }
  redactStart = null;
  render();
});

function askText(e: PointerEvent, at: [number, number]) {
  const input = el("input", "text-input");
  input.placeholder = t("Type, then Enter");
  const r = stage.getBoundingClientRect();
  input.style.left = `${e.clientX - r.left}px`;
  input.style.top = `${e.clientY - r.top - 18}px`;
  stage.append(input);
  input.focus();
  const finish = (keep: boolean) => {
    if (keep && input.value.trim()) marks.push({ tool: "text", color: markColor, points: [at], text: input.value.trim() });
    input.remove();
    render();
  };
  input.addEventListener("keydown", (k) => {
    k.stopPropagation();
    if (k.key === "Enter") finish(true);
    if (k.key === "Escape") finish(false);
  });
  input.addEventListener("blur", () => finish(true));
}

function undo() {
  if (tool === "annotate") marks.pop();
  if (tool === "redact") redactions.pop();
  render();
}

// ── The bars ────────────────────────────────────────────────────────────────

function toolTitle(): string {
  switch (tool) {
    case "crop":
      return t("Crop");
    case "edit":
      return t("Edit");
    case "annotate":
      return t("Annotate");
    case "redact":
      return t("Redact");
    case "background":
      return t("Background");
  }
}

function buildTop() {
  const title = el("div", "title");
  title.append(el("b", "", toolTitle()), el("span", "", editing?.name ?? ""));
  top.replaceChildren(title);
  if (tool === "crop") {
    const ratios: [number | null | "original", string][] = [
      [null, t("Free")],
      ["original", t("Original")],
      [1, "1:1"],
      [4 / 3, "4:3"],
      [3 / 2, "3:2"],
      [16 / 9, "16:9"],
      [9 / 16, "9:16"],
    ];
    let picked: number | null | "original" = null;
    top.append(
      choice(ratios, () => picked, (v) => {
        picked = v;
        aspect = v === "original" ? W / H : v;
        crop = initialCrop(aspect, W, H);
      }),
      button(t("Reset"), () => {
        crop = initialCrop(aspect, W, H);
        render();
      }),
    );
  } else if (tool === "edit") {
    top.append(
      slider(t("Brightness"), 40, 160, () => adjust.brightness, (v) => (adjust.brightness = v), "%"),
      slider(t("Contrast"), 40, 160, () => adjust.contrast, (v) => (adjust.contrast = v), "%"),
      slider(t("Saturation"), 0, 200, () => adjust.saturation, (v) => (adjust.saturation = v), "%"),
      slider(t("Warmth"), -100, 100, () => adjust.warmth, (v) => (adjust.warmth = v)),
      button(t("Reset"), () => {
        Object.assign(adjust, { brightness: 100, contrast: 100, saturation: 100, warmth: 0 });
        buildTop();
        render();
      }),
    );
  } else if (tool === "annotate") {
    top.append(
      choice<MarkTool>([["arrow", "↗", t("Arrow")], ["box", "▭", t("Box")], ["pen", "✎", t("Pen")], ["text", "T", t("Text")]], () => markTool, (v) => (markTool = v)),
      swatches(COLORS, () => markColor, (c) => (markColor = c)),
      button(t("Undo"), undo),
    );
  } else if (tool === "redact") {
    top.append(
      choice<"black" | "pixelate">([["black", t("Black box")], ["pixelate", t("Pixelate")]], () => redactMode, (v) => (redactMode = v)),
      button(t("Undo"), undo),
    );
  } else if (tool === "background") {
    const shapes: [number | null, string][] = [[null, t("Fit")], [1, "1:1"], [16 / 9, "16:9"], [4 / 3, "4:3"], [9 / 16, "9:16"]];
    top.append(
      swatches(Object.keys(FILLS), () => bg.fill, (f) => (bg.fill = f), (f) => css(FILLS[f])),
      slider(t("Padding"), 0, 30, () => Math.round(bg.padding * 100), (v) => (bg.padding = v / 100), "%"),
      slider(t("Corners"), 0, 15, () => Math.round(bg.corners * 100), (v) => (bg.corners = v / 100), "%"),
      choice<boolean>([[true, t("Shadow")], [false, "—"]], () => bg.shadow, (v) => (bg.shadow = v)),
      choice(shapes, () => bg.aspect, (v) => (bg.aspect = v)),
    );
  }
}

function buildBottom() {
  const save = button(t("Save"), () => void doSave(save), "primary");
  bottom.replaceChildren(
    el("span", "hint", tool === "annotate" || tool === "redact" ? "Ctrl+Z · Ctrl+S" : "Ctrl+S"),
    button(t("Cancel"), cancel, "ghost"),
    save,
  );
}

async function doSave(save: HTMLButtonElement) {
  save.disabled = true;
  try {
    const path = await invoke<string | null>("wheel_editor_done", { dataUrl: exportImage() });
    if (path) showSaved(path);
  } catch (e) {
    save.disabled = false;
    alert(String(e));
  }
}

function showSaved(path: string) {
  const box = el("div", "box");
  const check = el("div", "check");
  check.innerHTML = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5.5 12.5l4.2 4.2 8.8-9.2"/></svg>';
  const row = el("div", "row");
  row.append(
    button(t("Show in Explorer"), () => {
      void invoke("wheel_reveal", { path });
      void invoke("wheel_editor_close");
    }, "primary"),
    button(t("Done"), () => void invoke("wheel_editor_close"), "ghost"),
  );
  box.append(check, el("b", "", t("Saved")), el("div", "name", path.split(/[\\/]/).pop() ?? path), row);
  savedBox.replaceChildren(box);
  savedBox.classList.add("on");
}

function cancel() {
  void invoke("wheel_editor_done", { dataUrl: null });
}

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") cancel();
  else if (e.ctrlKey && e.key.toLowerCase() === "z") undo();
  else if (e.ctrlKey && e.key.toLowerCase() === "s") {
    e.preventDefault();
    const save = bottom.querySelector("button.primary") as HTMLButtonElement | null;
    if (save && !save.disabled) void doSave(save);
  }
});

new ResizeObserver(() => render()).observe(stage);

async function main() {
  const boot = await Bridge.boot();
  setLanguage(resolveLanguage(boot?.settings.language, systemLanguages()));
  editing = await invoke<Editing | null>("wheel_editing").catch(() => null);
  if (!editing) return void invoke("wheel_editor_close");
  tool = editing.tool;
  document.title = `${toolTitle()} · ${editing.name}`;
  img.onload = () => {
    W = img.naturalWidth;
    H = img.naturalHeight;
    crop = initialCrop(null, W, H);
    buildTop();
    buildBottom();
    render();
  };
  img.src = editing.image;
}

void main();

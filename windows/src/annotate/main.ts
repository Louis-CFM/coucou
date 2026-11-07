// The annotation window: arrows, boxes and a pen over a screen capture, then
// Done — port of CaptureAnnotationView (ScreenCapture.swift). The marks are
// kept in the image's own proportions and drawn again at its full size when
// you are done, so they stay sharp.

import { invoke } from "@tauri-apps/api/core";
import { Bridge } from "../core/bridge";
import { resolveLanguage, setLanguage, systemLanguages, t } from "../i18n/i18n";

type Tool = "arrow" | "box" | "pen";
interface Mark {
  tool: Tool;
  color: number;
  /** (0, 0) top left, (1, 1) bottom right of the image. */
  points: { x: number; y: number }[];
}

const COLORS = ["rgb(255,69,59)", "rgb(255,204,0)", "rgb(59,158,255)", "#ffffff"];

export function drawMark(c: CanvasRenderingContext2D, mark: Mark, w: number, h: number, lineWidth: number) {
  const pts = mark.points.map((p) => ({ x: p.x * w, y: p.y * h }));
  const first = pts[0];
  const last = pts[pts.length - 1];
  if (!first || !last) return;
  c.save();
  c.strokeStyle = COLORS[mark.color] ?? COLORS[0];
  c.lineWidth = lineWidth;
  c.lineCap = "round";
  c.lineJoin = "round";
  c.beginPath();
  if (mark.tool === "pen") {
    c.moveTo(first.x, first.y);
    for (const p of pts.slice(1)) c.lineTo(p.x, p.y);
  } else if (mark.tool === "box") {
    const x = Math.min(first.x, last.x);
    const y = Math.min(first.y, last.y);
    const r = lineWidth * 1.5;
    c.roundRect(x, y, Math.abs(last.x - first.x), Math.abs(last.y - first.y), r);
  } else {
    c.moveTo(first.x, first.y);
    c.lineTo(last.x, last.y);
    const head = lineWidth * 5;
    if (Math.hypot(last.x - first.x, last.y - first.y) > head * 0.5) {
      const angle = Math.atan2(last.y - first.y, last.x - first.x);
      for (const side of [-1, 1]) {
        const wing = angle + Math.PI + (side * Math.PI) / 7;
        c.moveTo(last.x, last.y);
        c.lineTo(last.x + Math.cos(wing) * head, last.y + Math.sin(wing) * head);
      }
    }
  }
  c.stroke();
  c.restore();
}

async function main() {
  const boot = await Bridge.boot();
  setLanguage(resolveLanguage(boot?.settings.language, systemLanguages()));
  document.title = t("Annotate");

  const dataUrl = await invoke<string | null>("capture_image").catch(() => null);
  const done = (result: string | null) => void invoke("capture_annotated", { dataUrl: result });
  if (!dataUrl) {
    done(null);
    return;
  }
  const image = new Image();
  image.src = dataUrl;
  await image.decode();

  let tool: Tool = "arrow";
  let color = 0;
  const marks: Mark[] = [];
  let drawing: Mark | null = null;

  const bar = document.getElementById("bar")!;
  const stage = document.getElementById("stage")!;
  const canvas = document.getElementById("canvas") as HTMLCanvasElement;
  const ctx = canvas.getContext("2d")!;

  const button = (label: string, title: string, onClick: () => void, cls = "") => {
    const b = document.createElement("button");
    b.textContent = label;
    b.title = title;
    if (cls) b.className = cls;
    b.addEventListener("click", onClick);
    return b;
  };
  const tools: [Tool, string][] = [["arrow", "↗"], ["box", "▭"], ["pen", "✎"]];
  const toolButtons = tools.map(([id, label]) => {
    const b = button(label, "", () => {
      tool = id;
      sync();
    }, "tool");
    b.dataset.tool = id;
    return b;
  });
  const swatches = COLORS.map((c, i) => {
    const b = button("", "", () => {
      color = i;
      sync();
    }, "swatch");
    b.style.background = c;
    return b;
  });
  const undo = button("↶", "Ctrl+Z", () => {
    marks.pop();
    paint();
    sync();
  }, "tool");
  const spacer = document.createElement("div");
  spacer.style.flex = "1";
  const cancel = button(t("Cancel"), "Esc", () => done(null));
  const ok = button(t("Done"), "Enter", () => done(render()), "primary");
  bar.append(...toolButtons, sep(), ...swatches, sep(), undo, spacer, cancel, ok);

  function sep() {
    const s = document.createElement("span");
    s.className = "sep";
    return s;
  }

  function sync() {
    for (const b of toolButtons) b.classList.toggle("on", b.dataset.tool === tool);
    swatches.forEach((b, i) => b.classList.toggle("on", i === color));
    undo.disabled = marks.length === 0;
  }

  /** The image fitted in the stage, as on the Mac. */
  function layout() {
    const box = stage.getBoundingClientRect();
    const s = Math.min(box.width / image.naturalWidth, box.height / image.naturalHeight, 1);
    const w = Math.max(1, Math.round(image.naturalWidth * s));
    const h = Math.max(1, Math.round(image.naturalHeight * s));
    const dpr = window.devicePixelRatio || 1;
    canvas.style.width = `${w}px`;
    canvas.style.height = `${h}px`;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    paint();
  }

  function paint() {
    const w = canvas.width / (window.devicePixelRatio || 1);
    const h = canvas.height / (window.devicePixelRatio || 1);
    ctx.clearRect(0, 0, w, h);
    ctx.drawImage(image, 0, 0, w, h);
    for (const m of drawing ? [...marks, drawing] : marks) drawMark(ctx, m, w, h, 3);
  }

  /** The capture with its marks, at its full size. */
  function render(): string | null {
    if (marks.length === 0) return null;
    const out = document.createElement("canvas");
    out.width = image.naturalWidth;
    out.height = image.naturalHeight;
    const c = out.getContext("2d")!;
    c.drawImage(image, 0, 0);
    for (const m of marks) drawMark(c, m, out.width, out.height, Math.max(3, out.width / 300));
    return out.toDataURL("image/png");
  }

  const at = (e: PointerEvent) => {
    const r = canvas.getBoundingClientRect();
    return {
      x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)),
      y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)),
    };
  };
  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    const p = at(e);
    drawing = { tool, color, points: [p, p] };
    paint();
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!drawing) return;
    const p = at(e);
    if (drawing.tool === "pen") drawing.points.push(p);
    else drawing.points[1] = p;
    paint();
  });
  const end = () => {
    if (drawing) marks.push(drawing);
    drawing = null;
    paint();
    sync();
  };
  canvas.addEventListener("pointerup", end);
  canvas.addEventListener("pointercancel", end);

  window.addEventListener("keydown", (e) => {
    if (e.key === "Escape") done(null);
    else if (e.key === "Enter") done(render());
    else if (e.key.toLowerCase() === "z" && (e.ctrlKey || e.metaKey)) {
      marks.pop();
      paint();
      sync();
    }
  });
  window.addEventListener("resize", layout);
  sync();
  layout();
}

void main();

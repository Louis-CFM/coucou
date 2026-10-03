// Generated media in the chat: the "making it" card while a model works, and
// the result (image, video or speech) with Download and a full-screen preview.

import type { AnimationItem } from "lottie-web";
import { h, svg } from "./dom";
import { ICONS } from "./icons";
import { Bridge, onEvent } from "../core/bridge";
import type { MediaFile, ModelOutput } from "../core/state";

/** blob: URLs of the files on show, kept so a chat re-render doesn't reload them. */
const urls = new Map<string, Promise<string | null>>();

function urlFor(name: string): Promise<string | null> {
  let url = urls.get(name);
  if (!url) {
    url = Bridge.mediaUrl(name);
    urls.set(name, url);
  }
  return url;
}

/** Stills of generated 3D models, rendered once per file. */
const stills = new Map<string, Promise<string | null>>();

function stillFor(name: string): Promise<string | null> {
  let still = stills.get(name);
  if (!still) {
    still = Bridge.mediaBytes(name).then((bytes) =>
      bytes ? import("./model3d").then((m) => m.snapshot(bytes)).catch(() => null) : null,
    );
    stills.set(name, still);
  }
  return still;
}

/** Clear chat: hand the files' memory back. */
export function releaseMedia() {
  for (const url of urls.values()) void url.then((u) => u && URL.revokeObjectURL(u));
  urls.clear();
  stills.clear();
}

// ── While it's being made ─────────────────────────────────────────────────────

/** Latest video progress (0–100) and when the generation began, kept so a
 *  re-render of the chat carries on where it was. */
let progress: number | null = null;
let startedAt = 0;
void onEvent<number | null>("media-progress", (p) => {
  progress = p;
  for (const el of document.querySelectorAll<HTMLElement>(".gen-card")) paintProgress(el);
});

function paintProgress(card: HTMLElement) {
  const bar = card.querySelector<HTMLElement>(".gen-bar");
  if (!bar) return;
  bar.classList.toggle("busy", progress == null);
  (bar.firstElementChild as HTMLElement).style.width = progress == null ? "" : `${Math.max(3, progress)}%`;
  const pct = card.querySelector(".gen-pct");
  if (pct) pct.textContent = progress == null ? "" : `${Math.round(progress)}%`;
}

const LABELS: Record<string, string> = { image: "Painting", video: "Rendering video", audio: "Recording voice", "3d": "Sculpting in 3D" };

/** A new generation starts: forget the last one's progress. */
export function resetProgress() {
  progress = null;
  startedAt = performance.now();
}

/**
 * The card shown while a model makes something. Image, video and 3D get the
 * "aurora": the shape of the coming picture, with colour drifting under a
 * band of pixels developing (all transforms and opacity, so the compositor
 * does the work). Video adds a progress bar. Speech plays a music-note
 * animation, recoloured with a turning rainbow.
 */
export function generatingCard(kind: ModelOutput): HTMLElement {
  const time = h("span", { class: "gen-time" });
  const visual =
    kind === "audio"
      ? noteLoader()
      : h(
          "div",
          { class: `gen-aurora ${kind}` },
          h("i"),
          h("i"),
          h("i"),
          h("b", { class: "gen-pixels" }),
          svg(SPARKLE, 16, { fill: "currentColor" }),
        );
  const card = h(
    "div",
    { class: "chat-row" },
    h(
      "div",
      { class: `gen-card ${kind}` },
      visual,
      h(
        "div",
        { class: "gen-text" },
        h("span", { class: "gen-label shimmer", text: `${LABELS[kind] ?? "Working"}…` }),
        h("span", { class: "gen-meta" }, time, h("span", { class: "gen-pct" })),
        kind === "video" ? h("div", { class: "gen-bar" }, h("i")) : null,
      ),
    ),
  );
  const made = performance.now();
  const tick = () => {
    if (!card.isConnected && performance.now() - made > 1000) return; // replaced: stop
    const s = Math.floor((performance.now() - startedAt) / 1000);
    time.textContent = s < 60 ? `${s}s` : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    window.setTimeout(tick, 1000);
  };
  tick();
  paintProgress(card);
  return card;
}

/**
 * The music-note loader (assets/music-loading.json, a Lottie) on a canvas.
 * Each frame is drawn, then painted over "source-in" with a turning rainbow,
 * so the whole animation takes the gradient. lottie-web loads on first use.
 */
function noteLoader(): HTMLElement {
  const size = 44;
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  const canvas = h("canvas", { class: "gen-note", width: size * dpr, height: size * dpr });
  const ctx = canvas.getContext("2d");
  if (!ctx) return canvas;
  void Promise.all([import("lottie-web/build/player/lottie_light_canvas"), import("../assets/music-loading.json")]).then(
    ([lottie, data]) => {
      // The light canvas build's typings only describe the SVG renderer.
      const player = lottie.default as unknown as { loadAnimation(params: object): AnimationItem };
      const anim = player.loadAnimation({
        renderer: "canvas",
        loop: true,
        autoplay: false,
        animationData: structuredClone(data.default),
        rendererSettings: { context: ctx, clearCanvas: true, preserveAspectRatio: "xMidYMid meet" },
      });
      const frames = anim.totalFrames;
      const t0 = performance.now();
      const draw = (now: number) => {
        if (!canvas.isConnected && now - t0 > 1000) {
          anim.destroy();
          return;
        }
        const t = (now - t0) / 1000;
        anim.goToAndStop((t * 60) % frames, true);
        ctx.save();
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.globalCompositeOperation = "source-in";
        const c = canvas.width / 2;
        const rainbow = ctx.createConicGradient(t * 2.4, c, c);
        ["#ff6b5b", "#f7b32b", "#2dd4a7", "#38bdf8", "#a78bfa", "#ff6b5b"].forEach((col, i, all) =>
          rainbow.addColorStop(i / (all.length - 1), col),
        );
        ctx.fillStyle = rainbow;
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.restore();
        requestAnimationFrame(draw);
      };
      requestAnimationFrame(draw);
    },
  );
  return canvas;
}

/** A four-point sparkle, the "generating" mark. */
const SPARKLE = "M12 1.5c.5 4.6 2.2 6.9 5.2 8.2 1.3.6 2.8.9 4.3 1.3v2c-1.5.4-3 .7-4.3 1.3-3 1.3-4.7 3.6-5.2 8.2h-.1c-.5-4.6-2.2-6.9-5.2-8.2C5.4 13.7 3.9 13.4 2.4 13v-2c1.5-.4 3-.7 4.3-1.3 3-1.3 4.7-3.6 5.2-8.2h.1z";

// ── The result ────────────────────────────────────────────────────────────────

/** One generated file, inline, with Download and (image, video) Full screen. */
export function mediaCard(file: MediaFile): HTMLElement {
  if (file.kind === "3d") return modelCard(file);
  const el =
    file.kind === "image"
      ? (h("img", { class: "media-view", alt: "Generated image", title: "Click for full screen" }) as HTMLImageElement)
      : file.kind === "video"
        ? (h("video", { class: "media-view", controls: true, preload: "metadata", playsinline: true }) as HTMLVideoElement)
        : (h("audio", { class: "media-audio", controls: true, preload: "auto" }) as HTMLAudioElement);
  void urlFor(file.name).then((url) => {
    if (url) el.src = url;
    else el.replaceWith(h("div", { class: "reply-note", text: "This file is gone from the media folder." }));
  });

  const actions = h("div", { class: "media-actions" });
  if (file.kind !== "audio") {
    const full = h("button", { class: "code-copy", title: "Full screen (Esc to close)" }, svg(ICONS.expand, 11), "Full screen");
    full.addEventListener("click", (e) => {
      e.stopPropagation();
      if (el instanceof HTMLVideoElement) el.pause();
      void Bridge.mediaPreview(file);
    });
    actions.append(full);
    if (file.kind === "image") el.addEventListener("click", () => void Bridge.mediaPreview(file));
  }
  const save = h("button", { class: "code-copy", title: "Save a copy in Downloads" });
  const reset = () => save.replaceChildren(svg(ICONS.download, 11), document.createTextNode("Download"));
  reset();
  save.addEventListener("click", async (e) => {
    e.stopPropagation();
    try {
      const path = await Bridge.mediaDownload(file.name);
      save.replaceChildren(svg(ICONS.check, 11, { stroke: 2.4 }), document.createTextNode("In Downloads"));
      save.title = path;
    } catch (err) {
      save.replaceChildren(document.createTextNode(String(err).replace(/^Error:\s*/, "")));
    }
    window.setTimeout(reset, 2200);
  });
  actions.append(save);
  return h("div", { class: `media-card ${file.kind}` }, el, actions);
}

/** A generated 3D model: a rendered still (click to turn it around full
 *  screen) and Download. Gaussian splats (.ply) can't be shown here. */
function modelCard(file: MediaFile): HTMLElement {
  const splat = file.name.endsWith(".ply");
  const view = splat
    ? h("div", { class: "reply-note", text: "A Gaussian splat (.ply): download it to open in a splat viewer." })
    : (h("img", { class: "media-view model3d", alt: "Generated 3D model", title: "Click to turn it around" }) as HTMLImageElement);
  if (view instanceof HTMLImageElement) {
    void stillFor(file.name).then((still) => {
      if (still) view.src = still;
      else view.replaceWith(h("div", { class: "reply-note", text: "Couldn't show this 3D model; it can still be downloaded." }));
    });
    view.addEventListener("click", () => void Bridge.mediaPreview(file));
  }
  const actions = h("div", { class: "media-actions" });
  if (!splat) {
    const turn = h("button", { class: "code-copy", title: "Turn it around, full screen (Esc to close)" }, svg(ICONS.expand, 11), "View in 3D");
    turn.addEventListener("click", (e) => {
      e.stopPropagation();
      void Bridge.mediaPreview(file);
    });
    actions.append(turn);
  }
  const save = h("button", { class: "code-copy", title: "Save a copy in Downloads" });
  const reset = () => save.replaceChildren(svg(ICONS.download, 11), document.createTextNode(splat ? "Download .ply" : "Download .glb"));
  reset();
  save.addEventListener("click", async (e) => {
    e.stopPropagation();
    try {
      save.title = await Bridge.mediaDownload(file.name);
      save.replaceChildren(svg(ICONS.check, 11, { stroke: 2.4 }), document.createTextNode("In Downloads"));
    } catch (err) {
      save.replaceChildren(document.createTextNode(String(err).replace(/^Error:\s*/, "")));
    }
    window.setTimeout(reset, 2200);
  });
  actions.append(save);
  return h("div", { class: "media-card model3d" }, view, actions);
}

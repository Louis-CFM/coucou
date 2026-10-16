// Generated media in the chat: the "making it" card while a model works, and
// the result (image, video, speech or a 3D file) with Download.

import { h, svg } from "./dom";
import { ICONS } from "./icons";
import { Bridge, onEvent } from "../core/bridge";
import type { MediaFile, ModelOutput } from "../core/state";
import { t } from "../i18n/i18n";

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

/** A new chat: hand the files' memory back. */
export function releaseMedia() {
  for (const url of urls.values()) void url.then((u) => u && URL.revokeObjectURL(u));
  urls.clear();
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
 * The card shown while a model makes something: the "aurora", the shape of
 * the coming result, with colour drifting under a band of pixels developing
 * (all transforms and opacity, so the compositor does the work). Video adds a
 * progress bar.
 */
export function generatingCard(kind: ModelOutput): HTMLElement {
  const time = h("span", { class: "gen-time" });
  const visual = h(
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

/** A four-point sparkle, the "generating" mark. */
const SPARKLE = "M12 1.5c.5 4.6 2.2 6.9 5.2 8.2 1.3.6 2.8.9 4.3 1.3v2c-1.5.4-3 .7-4.3 1.3-3 1.3-4.7 3.6-5.2 8.2h-.1c-.5-4.6-2.2-6.9-5.2-8.2C5.4 13.7 3.9 13.4 2.4 13v-2c1.5-.4 3-.7 4.3-1.3 3-1.3 4.7-3.6 5.2-8.2h.1z";

// ── The result ────────────────────────────────────────────────────────────────

/** One generated file, inline, with Download. */
export function mediaCard(file: MediaFile): HTMLElement {
  if (file.kind === "3d") return modelCard(file);
  const el =
    file.kind === "image"
      ? (h("img", { class: "media-view", alt: "Generated image" }) as HTMLImageElement)
      : file.kind === "video"
        ? (h("video", { class: "media-view", controls: true, preload: "metadata", playsinline: true }) as HTMLVideoElement)
        : (h("audio", { class: "media-audio", controls: true, preload: "auto" }) as HTMLAudioElement);
  void urlFor(file.name).then((url) => {
    if (url) el.src = url;
    else el.replaceWith(h("div", { class: "reply-note", text: "This file is gone from the media folder." }));
  });

  const actions = h("div", { class: "media-actions" }, downloadButton(file, t("Download")));
  return h("div", { class: `media-card ${file.kind}` }, el, actions);
}

/** Download: a copy of the file in Downloads, the button saying how it went. */
function downloadButton(file: MediaFile, label: string): HTMLElement {
  const save = h("button", { class: "code-copy", title: "Save a copy in Downloads" });
  const reset = () => save.replaceChildren(svg(ICONS.download, 11), document.createTextNode(label));
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
  return save;
}

/** A generated 3D model: a file to open in a 3D viewer, and Download. */
function modelCard(file: MediaFile): HTMLElement {
  const splat = file.name.endsWith(".ply");
  const text = splat
    ? "A Gaussian splat (.ply): download it to open in a splat viewer."
    : "A 3D model (.glb): download it to open in a 3D viewer.";
  const actions = h("div", { class: "media-actions" }, downloadButton(file, splat ? "Download .ply" : "Download .glb"));
  return h("div", { class: "media-card model3d" }, h("div", { class: "reply-note", text }), actions);
}

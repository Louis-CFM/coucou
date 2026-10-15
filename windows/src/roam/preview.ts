// Full-screen preview of a generated image or video, on the roam overlay (see
// media_preview in src-tauri/src/media.rs for why this window). Esc, a click
// outside the picture or the close button ends it.

import "./preview.css";
import { listen } from "@tauri-apps/api/event";
import { Bridge } from "../core/bridge";
import type { MediaFile } from "../core/state";
import { ICONS } from "../views/icons";
import { h, svg } from "../views/dom";

const root = h("div", { class: "preview", hidden: true });
document.body.append(root);
let url: string | null = null;
/** Stops a 3D turntable and frees its GPU context. */
let stopViewer: (() => void) | null = null;

function close() {
  if (root.hidden) return;
  root.hidden = true;
  stopViewer?.();
  stopViewer = null;
  root.replaceChildren(); // stops a video
  if (url) URL.revokeObjectURL(url);
  url = null;
  void Bridge.mediaPreviewClose();
}

void listen<MediaFile>("preview-open", async (e) => {
  const file = e.payload;
  if (url) URL.revokeObjectURL(url);
  const shut = h("button", { class: "preview-close", title: "Close (Esc)" }, svg(ICONS.xmark, 16));
  shut.addEventListener("click", close);
  root.replaceChildren(shut);
  root.hidden = false;
  if (file.kind === "3d") {
    // Drag to turn, scroll to zoom; a click outside the stage closes.
    const stagebox = h("div", { class: "preview-3d" });
    root.append(stagebox, h("div", { class: "preview-hint", text: "Drag to turn \u00b7 scroll to zoom \u00b7 Esc to close" }));
    const bytes = await Bridge.mediaBytes(file.name);
    if (!bytes || root.hidden) return close();
    const { mountViewer } = await import("../views/model3d");
    stopViewer?.();
    stopViewer = await mountViewer(stagebox, bytes).catch(() => null);
    if (!stopViewer) return close();
    if (root.hidden) {
      stopViewer();
      stopViewer = null;
    }
    return;
  }
  url = await Bridge.mediaUrl(file.name);
  if (!url || root.hidden) return close();
  root.append(
    file.kind === "video"
      ? h("video", { class: "preview-media", src: url, controls: true, autoplay: true })
      : h("img", { class: "preview-media", src: url, alt: "Generated image" }),
  );
});

// A click on the dimmed backdrop, not on the picture or the video's controls.
root.addEventListener("click", (e) => e.target === root && close());
window.addEventListener(
  "keydown",
  (e) => {
    if (e.key !== "Escape" || root.hidden) return;
    e.stopImmediatePropagation();
    close();
  },
  true,
);

// Vayli Drop / Coudrop view (windows/src/views/coudrop.ts)
// Zero-QR Device-Aware File Transfer reusing Coucou Desktop <-> Android TLS Connection.
// macOS Dynamic Island Dual-Studio Architecture.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { State } from "../core/state";
import { Bridge, IS_TAURI, onEvent, type CoudropReceivedFile, type CoudropProgress } from "../core/bridge";
import type { ViewActions, ViewHost } from "./views";
import { Sound } from "../core/sound";
import { t, tl } from "../i18n/i18n";

/** Format byte size to human readable */
function formatBytes(bytes: number | null | undefined): string {
  if (bytes == null || !Number.isFinite(bytes) || bytes <= 0) return "0 B";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Animated dashed rounded rect SVG frame matching Coucou's signature macOS theme */
function dashedFrame(): SVGSVGElement {
  const ns = "http://www.w3.org/2000/svg";
  const el = document.createElementNS(ns, "svg");
  el.setAttribute("class", "coudrop-transmitter-frame");
  el.setAttribute("preserveAspectRatio", "none");
  const rect = document.createElementNS(ns, "rect");
  rect.setAttribute("x", "1");
  rect.setAttribute("y", "1");
  rect.setAttribute("width", "calc(100% - 2px)");
  rect.setAttribute("height", "calc(100% - 2px)");
  rect.setAttribute("rx", "16");
  rect.setAttribute("fill", "none");
  rect.setAttribute("stroke-width", "1.5");
  rect.setAttribute("stroke-dasharray", "6 5");
  el.append(rect);
  return el;
}

export function buildCoudrop(_actions: ViewActions): ViewHost {
  const root = h("div", { class: "view coudrop-root" });
  let listenersBound = false;
  let isSending = false;
  let isCardDragOver = false;

  // Hidden native file picker for selecting files
  const fileInput = h("input", {
    type: "file",
    multiple: "true",
    style: "display:none",
  }) as HTMLInputElement;

  fileInput.addEventListener("change", () => {
    if (fileInput.files && fileInput.files.length > 0) {
      const files = Array.from(fileInput.files);
      const paths = files
        .map((f) => (f as unknown as { path?: string }).path || f.name)
        .filter(Boolean);
      fileInput.value = "";
      if (paths.length > 0) {
        void sendFiles(paths);
      }
    }
  });

  function bindEventsOnce() {
    if (listenersBound) return;
    listenersBound = true;

    // Detect initial device status and history
    if (IS_TAURI) {
      void Bridge.coudropGetDevice().then((dev) => {
        if (dev && dev.connected) {
          State.coudropConnected = true;
          State.coudropConnectedDevice = dev.name || t("Phone");
        } else {
          State.coudropConnected = false;
          State.coudropConnectedDevice = null;
        }
        sync();
      });

      void Bridge.coudropGetHistory().then((history) => {
        if (!State.coudropHistoryCleared && history && history.length > 0) {
          State.coudropReceivedFiles = history;
          sync();
        }
      });
    }

    void onEvent<{ device?: string; name?: string }>("coudrop-phone-connected", (payload) => {
      State.coudropConnected = true;
      State.coudropConnectedDevice = payload.name || payload.device || t("Phone");
      Sound.play("pop");
      sync();
    });

    void onEvent<{ device?: string; name?: string }>("coudrop-phone-disconnected", () => {
      State.coudropConnected = false;
      State.coudropConnectedDevice = null;
      sync();
    });

    let progressRaf = 0;
    void onEvent<CoudropProgress>("coudrop-progress", (prog: CoudropProgress) => {
      if (!prog) return;
      isSending = true;
      State.coudropProgress = prog;
      if (!progressRaf) {
        progressRaf = requestAnimationFrame(() => {
          progressRaf = 0;
          sync();
        });
      }
    });

    void onEvent<CoudropReceivedFile>("coudrop-file-received", (file: CoudropReceivedFile) => {
      isSending = false;
      State.coudropProgress = null;
      if (file && file.name && typeof file.size === "number" && Number.isFinite(file.size)) {
        State.coudropHistoryCleared = false;
        State.coudropReceivedFiles.unshift(file);
        State.coudropLastReceivedFile = file;
      }
      Sound.play("done");
      sync();
    });

    void onEvent<CoudropReceivedFile>("coudrop-file-sent", (file: CoudropReceivedFile) => {
      isSending = false;
      State.coudropProgress = null;
      if (file && file.name && typeof file.size === "number" && Number.isFinite(file.size)) {
        State.coudropHistoryCleared = false;
        State.coudropReceivedFiles.unshift(file);
        State.coudropLastReceivedFile = file;
      }
      Sound.play("done");
      sync();
    });

    void onEvent("coudrop-cancel", () => {
      isSending = false;
      State.coudropProgress = null;
      sync();
    });
  }

  async function sendFiles(paths: string[]) {
    if (!State.coudropConnected) {
      Sound.play("deny");
      alert(tl("Your phone is currently offline. Make sure Coucou is open on your phone."));
      return;
    }

    isSending = true;
    Sound.play("blip");
    sync();

    if (!IS_TAURI) {
      // Browser preview simulated transfer
      let pct = 0;
      const fakeTimer = setInterval(() => {
        pct += 10;
        if (pct >= 100) {
          clearInterval(fakeTimer);
          isSending = false;
          State.coudropProgress = null;
          State.coudropReceivedFiles.unshift({
            name: paths[0].split("/").pop() || "sample_file.png",
            path: paths[0],
            size: 1542890,
          });
          Sound.play("done");
          sync();
        } else {
          State.coudropProgress = {
            name: paths[0].split("/").pop() || "sample_file.png",
            bytesRead: Math.floor((1542890 * pct) / 100),
            totalBytes: 1542890,
            progress: pct / 100,
          };
          sync();
        }
      }, 100);
      return;
    }

    try {
      await Bridge.coudropSendFiles(paths);
    } catch (err) {
      console.error("[coudrop] Transfer failed:", err);
      const msg = err instanceof Error ? err.message : String(err);
      alert(msg || tl("File transfer could not be completed."));
    } finally {
      isSending = false;
      State.coudropProgress = null;
      sync();
    }
  }

  async function chooseAndSendFiles() {
    if (IS_TAURI) {
      try {
        const paths = await Bridge.coudropPickFiles();
        if (paths && paths.length > 0) {
          void sendFiles(paths);
        }
      } catch (err) {
        console.error("[coudrop] Failed to pick files:", err);
      }
    } else {
      fileInput.click();
    }
  }

  // ── 1. Left Studio: AirDrop Transmitter ────────────────────────────────────
  function renderTransmitter(): HTMLElement {
    // 1. Minimal blue upload icon (SVG arrow up with base tray)
    const iconSvg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    iconSvg.setAttribute("width", "20");
    iconSvg.setAttribute("height", "20");
    iconSvg.setAttribute("viewBox", "0 0 24 24");
    iconSvg.setAttribute("fill", "none");
    iconSvg.setAttribute("stroke", "currentColor");
    iconSvg.setAttribute("stroke-width", "2");
    iconSvg.setAttribute("stroke-linecap", "round");
    iconSvg.setAttribute("stroke-linejoin", "round");

    const arrowLine = document.createElementNS("http://www.w3.org/2000/svg", "path");
    arrowLine.setAttribute("d", "M12 16V4");
    const arrowHead = document.createElementNS("http://www.w3.org/2000/svg", "path");
    arrowHead.setAttribute("d", "M6 10l6-6 6 6");
    const baseTray = document.createElementNS("http://www.w3.org/2000/svg", "path");
    baseTray.setAttribute("d", "M4 20h16");

    iconSvg.append(arrowLine, arrowHead, baseTray);

    const iconBadge = h("div", { class: `coudrop-upload-icon border-2 border2 ${isSending ? "sending" : ""}` }, iconSvg);

    // 2. Primary text: "Drop files to send"
    const title = h("div", { class: "coudrop-title", text: tl("Drop files to send") });

    // 3. Secondary clickable text: "or browse files"
    const browseAction = h("span", {
      class: "coudrop-browse-action",
      text: tl("or browse files"),
      onclick: (e: Event) => {
        e.stopPropagation();
        void chooseAndSendFiles();
      },
    });

    const content = h(
      "div",
      { class: "coudrop-transmitter-content" },
      iconBadge,
      title,
      browseAction,
    );

    const card = h(
      "div",
      {
        class: `coudrop-transmitter ${isCardDragOver ? "drag-over" : ""} ${isSending ? "in-progress" : ""}`,
        onclick: () => void chooseAndSendFiles(),
      },
      dashedFrame(),
      content,
    );

    // HTML5 drag and drop listeners on transmitter
    card.addEventListener("dragenter", (e: DragEvent) => {
      e.preventDefault();
      e.stopPropagation();
      isCardDragOver = true;
      card.classList.add("drag-over");
    });

    card.addEventListener("dragover", (e: DragEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
      isCardDragOver = true;
      card.classList.add("drag-over");
    });

    card.addEventListener("dragleave", (e: DragEvent) => {
      e.preventDefault();
      e.stopPropagation();
      isCardDragOver = false;
      card.classList.remove("drag-over");
    });

    card.addEventListener("drop", (e: DragEvent) => {
      e.preventDefault();
      e.stopPropagation();
      isCardDragOver = false;
      card.classList.remove("drag-over");
      if (e.dataTransfer?.files && e.dataTransfer.files.length > 0) {
        const files = Array.from(e.dataTransfer.files);
        const paths = files
          .map((f) => (f as unknown as { path?: string }).path || f.name)
          .filter(Boolean);
        if (paths.length > 0) {
          void sendFiles(paths);
        }
      }
    });

    return card;
  }

  // ── 2. Right Studio: Device Hub & Transfer History ─────────────────────────
  function renderHub(): HTMLElement {
    const isOnline = State.coudropConnected;
    const devName = State.coudropConnectedDevice || t("Phone");
    const history = State.coudropReceivedFiles;

    // Device Header Card
    const dot = h("div", { class: `coudrop-device-dot ${isOnline ? "" : "offline"}` });
    const nameEl = h("span", { class: "coudrop-device-name", text: isOnline ? devName : tl("Phone offline") });
    const statusText = h("span", {
      class: "coudrop-device-status",
      text: isOnline ? tl("Paired Phone") : tl("Phone offline"),
    });

    const infoWrap = h("div", { class: "coudrop-device-info" }, nameEl, statusText);
    const leftHeader = h("div", { class: "coudrop-device-pill" }, dot, infoWrap);

    const folderBtn = h(
      "button",
      {
        class: "coudrop-folder-btn",
        type: "button",
        title: tl("Open folder in Explorer"),
        onclick: (e: Event) => {
          e.stopPropagation();
          void Bridge.coudropOpenFolder();
        },
      },
      svg(ICONS.folder, 13),
      h("span", { text: tl("Downloads") }),
    );

    const header = h("div", { class: "coudrop-hub-header" }, leftHeader, folderBtn);
    const divider = h("div", { class: "coudrop-hub-divider" });

    // History section with title and Clear action
    const historyTitle = h("div", { class: "coudrop-hub-section-title", text: tl("Recent transfers") });

    const clearBtn = history.length > 0
      ? h(
          "button",
          {
            class: "coudrop-clear-btn",
            type: "button",
            title: tl("Clear"),
            onclick: (e: Event) => {
              e.stopPropagation();
              State.coudropReceivedFiles = [];
              State.coudropHistoryCleared = true;
              sync();
            },
          },
          h("span", { text: tl("Clear") }),
        )
      : null;

    const historyHeader = h("div", { class: "coudrop-history-header" }, historyTitle, clearBtn);

    let historyContent: HTMLElement;
    if (history.length === 0) {
      historyContent = h(
        "div",
        { class: "coudrop-history-empty" },
        h("span", { text: tl("Recent transfers") }),
      );
    } else {
      const list = h("div", { class: "coudrop-history-list" });
      for (const f of history.slice(0, 8)) {
        const row = h(
          "div",
          {
            class: "coudrop-file-row",
            title: f.path || f.name,
            onclick: (e: Event) => {
              e.stopPropagation();
              if (f.path) void Bridge.coudropOpenFile(f.path);
            },
          },
          h("div", { class: "coudrop-file-icon-badge" }, svg(ICONS.check, 11)),
          h("span", { class: "coudrop-file-name", text: f.name }),
          h("span", { class: "coudrop-file-size", text: formatBytes(f.size) }),
          h("div", { class: "coudrop-file-action", title: tl("Open") }, svg(ICONS.arrowUpRight, 11)),
        );
        list.append(row);
      }
      historyContent = list;
    }

    return h("div", { class: "coudrop-hub" }, header, divider, historyHeader, historyContent);
  }

  function sync() {
    bindEventsOnce();
    clear(root);

    root.append(fileInput);

    const dualContainer = h(
      "div",
      { class: "card coudrop-card" },
      renderTransmitter(),
      renderHub(),
    );

    root.append(dualContainer);
  }

  return {
    el: root,
    sync,
    onDragOver(isOver: boolean) {
      isCardDragOver = isOver;
      const transmitter = root.querySelector(".coudrop-transmitter");
      if (transmitter) {
        if (isOver) transmitter.classList.add("drag-over");
        else transmitter.classList.remove("drag-over");
      }
    },
    onFileDrop(paths: string[]) {
      isCardDragOver = false;
      const transmitter = root.querySelector(".coudrop-transmitter");
      if (transmitter) transmitter.classList.remove("drag-over");
      if (paths.length > 0) {
        void sendFiles(paths);
      }
    },
  };
}

// Settings → Coudrop (windows/src/settings/coudrop.ts)
// macOS Sequoia / Sonoma Inset Grouped Settings Panel for Coudrop
// Device status, dynamic download folder picker, auto-open, sounds, and transfer history.

import { Bridge, type CoudropReceivedFile } from "../core/bridge";
import type { Settings } from "../core/state";
import { State } from "../core/state";
import { h, svg } from "../views/dom";
import { ICONS } from "../views/icons";
import { tl } from "../i18n/i18n";

type Toggle = (on: boolean, onChange: (v: boolean) => void) => HTMLElement;
type Save = (patch: Partial<Settings>) => Promise<void>;

/** Format byte size to human readable */
function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function coudropSettingsSection(
  makeToggle: Toggle,
  settings: Settings,
  save: Save,
): HTMLElement {
  const section = h("section", { class: "coudrop-settings-section" });
  const note = h("div", { class: "hint" });

  // Native hidden file picker for sending files directly from settings
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
        void Bridge.coudropSendFiles(paths).then(() => {
          note.textContent = `Sending ${paths.length} file(s) to phone...`;
        }).catch((err) => {
          note.textContent = String(err);
        });
      }
    }
  });

  // 1. Heading
  const heading = h("h2", {}, h("span", { text: "Coudrop" }));
  const intro = h(
    "div",
    {
      class: "coudrop-row-desc",
      style: "margin-top: -6px; margin-bottom: 2px;",
      text:
        "Zero-cloud peer-to-peer file transfer between your PC and Android phone over your private TLS connection. No file size limits, no compression, and no internet relay required.",
    },
  );

  // 2. Apple Continuity / AirDrop Hero Device Status Card
  const isOnline = State.coudropConnected;
  const devName = State.coudropConnectedDevice || tl("Paired Phone");

  const dot = h("div", {
    class: `coudrop-status-indicator ${isOnline ? "" : "offline"}`,
  });
  const devTitle = h("span", {
    class: "coudrop-device-title",
    text: isOnline ? devName : tl("Phone offline"),
  });
  const devStatus = h("span", {
    class: "coudrop-device-status",
    text: isOnline ? "Ready to receive" : "Open Coucou on your phone to connect",
  });
  const devInfo = h("div", { class: "coudrop-device-meta" }, devTitle, devStatus);
  const devLeft = h("div", { class: "coudrop-device-left" }, dot, devInfo);

  const sendBtn = h("button", {
    class: "coudrop-mac-btn",
    text: "Send files to phone…",
    onclick: () => fileInput.click(),
  });

  const devCard = h("div", { class: "coudrop-hero-card" }, devLeft, sendBtn);

  // 3. macOS Inset Group: Preferences
  const prefGroup = h("div", { class: "coudrop-group" });

  // 3a. Notch Header Tab Switch
  const notchTabSwitch = makeToggle(settings.showTabCoudrop !== false, (next) => {
    void save({ showTabCoudrop: next });
  });
  const notchLabelGroup = h(
    "div",
    { class: "coudrop-row-label-group" },
    h("span", { class: "coudrop-row-title", text: "Show Coudrop in Notch header" }),
    h("span", {
      class: "coudrop-row-desc",
      text: "Displays the Coudrop drop target tab in your top notch navigation bar for instant access.",
    }),
  );
  const notchRow = h("div", { class: "coudrop-group-row" }, notchLabelGroup, notchTabSwitch);

  // 3b. Auto-Open Received Files Switch
  const autoOpenSwitch = makeToggle(settings.coudropAutoOpen ?? false, (next) => {
    void save({ coudropAutoOpen: next });
  });
  const autoOpenLabelGroup = h(
    "div",
    { class: "coudrop-row-label-group" },
    h("span", { class: "coudrop-row-title", text: "Auto-open received files" }),
    h("span", {
      class: "coudrop-row-desc",
      text: "Automatically opens received photos, documents, and files in your default Windows apps.",
    }),
  );
  const autoOpenRow = h("div", { class: "coudrop-group-row" }, autoOpenLabelGroup, autoOpenSwitch);

  // 3c. Sound Effects Switch
  const soundSwitch = makeToggle(settings.coudropSound !== false, (next) => {
    void save({ coudropSound: next });
  });
  const soundLabelGroup = h(
    "div",
    { class: "coudrop-row-label-group" },
    h("span", { class: "coudrop-row-title", text: "Transfer sound effects" }),
    h("span", {
      class: "coudrop-row-desc",
      text: "Plays audio chimes when file transfers start and complete.",
    }),
  );
  const soundRow = h("div", { class: "coudrop-group-row" }, soundLabelGroup, soundSwitch);

  prefGroup.append(notchRow, autoOpenRow, soundRow);

  // 4. macOS Inset Group: Download Location (Apple HIG Path Capsule)
  const storageGroup = h("div", { class: "coudrop-group" });

  const pathDisplay = h("span", {
    class: "coudrop-path-text",
    text: tl("Loading…"),
  }) as HTMLSpanElement;

  const folderIcon = svg(ICONS.folder, 14);
  const pathCapsule = h(
    "div",
    { class: "coudrop-path-capsule", title: "Destination folder" },
    h("span", { class: "coudrop-path-icon" }, folderIcon),
    pathDisplay,
  );

  const browseBtn = h("button", {
    class: "coudrop-mac-btn",
    text: "Browse…",
  });
  const resetBtn = h("button", {
    class: "coudrop-mac-btn subtle",
    text: "Reset",
    style: "display: none;",
  });
  const openFolderBtn = h("button", {
    class: "coudrop-mac-btn",
    text: "Open folder",
    onclick: () => void Bridge.coudropOpenFolder(),
  });

  const updatePathDisplay = (dir: string) => {
    if (dir) {
      pathDisplay.textContent = dir;
      pathCapsule.title = dir;
      resetBtn.style.display = "";
    } else {
      pathDisplay.textContent = "Default (Downloads\\Coudrop)";
      pathCapsule.title = "Default: Downloads\\Coudrop";
      resetBtn.style.display = "none";
    }
  };

  // Load current setting on open
  void Bridge.coudropGetDownloadDir().then((dir) => {
    updatePathDisplay(dir || "");
  });

  browseBtn.addEventListener("click", async () => {
    browseBtn.disabled = true;
    try {
      const chosen = await Bridge.coudropPickDownloadDir();
      if (chosen) {
        await Bridge.coudropSetDownloadDir(chosen);
        await save({ coudropDownloadDir: chosen });
        updatePathDisplay(chosen);
      }
    } catch {
      // Ignore cancellation / errors
    } finally {
      browseBtn.disabled = false;
    }
  });

  resetBtn.addEventListener("click", async () => {
    await Bridge.coudropSetDownloadDir("");
    await save({ coudropDownloadDir: "" });
    updatePathDisplay("");
  });

  const folderLabelGroup = h(
    "div",
    { class: "coudrop-row-label-group" },
    h("span", { class: "coudrop-row-title", text: "Download folder" }),
    h("span", {
      class: "coudrop-row-desc",
      text: "Files received from your phone are saved here. Choose any folder or reset to default.",
    }),
  );

  const actionBtns = h("div", { class: "coudrop-action-btns" }, browseBtn, resetBtn, openFolderBtn);
  const folderControls = h("div", { class: "coudrop-folder-control" }, pathCapsule, actionBtns);

  const folderRow = h("div", { class: "coudrop-group-row" }, folderLabelGroup, folderControls);
  storageGroup.append(folderRow);

  // 5. Recent Transfers List (macOS Style List Card)
  const historyContainer = h("div", { style: "display: flex; flex-direction: column; gap: 8px;" });
  const historyTitle = h("h3", {
    style:
      "font-family: var(--font-sub); font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: rgba(255, 255, 255, 0.4); margin-left: 2px;",
    text: tl("Recent transfers"),
  });

  const historyCard = h("div", {
    class: "coudrop-history-card",
    style: "max-height: 200px; overflow-y: auto;",
  });

  const renderHistory = (files: CoudropReceivedFile[]) => {
    historyCard.replaceChildren();
    if (!files || files.length === 0) {
      historyCard.append(
        h("div", {
          class: "coudrop-row-desc",
          style: "padding: 16px; text-align: center; color: rgba(255, 255, 255, 0.35);",
          text: "No files transferred yet. Drop files onto the Notch or share from your phone!",
        }),
      );
      return;
    }
    for (const file of files.slice(0, 10)) {
      const checkIcon = svg(ICONS.check, 12);
      const fileItem = h(
        "div",
        { class: "coudrop-history-item" },
        h(
          "div",
          { class: "coudrop-history-item-left" },
          h("span", { style: "color: #22c55e; display: flex; align-items: center;" }, checkIcon),
          h("span", { class: "coudrop-history-item-name", text: file.name }),
        ),
        h(
          "div",
          { style: "display: flex; align-items: center; gap: 10px; flex-shrink: 0;" },
          h("span", { class: "coudrop-history-item-size", text: formatBytes(file.size) }),
          h("button", {
            class: "coudrop-mac-btn",
            style: "padding: 2px 8px; font-size: 11px;",
            text: tl("Open"),
            onclick: () => {
              if (file.path) void Bridge.coudropOpenFile(file.path);
            },
          }),
        ),
      );
      historyCard.append(fileItem);
    }
  };

  void Bridge.coudropGetHistory().then((history) => {
    renderHistory(history || State.coudropReceivedFiles);
  });

  historyContainer.append(historyTitle, historyCard);

  section.append(
    fileInput,
    heading,
    intro,
    devCard,
    prefGroup,
    storageGroup,
    historyContainer,
    note,
  );

  return section;
}

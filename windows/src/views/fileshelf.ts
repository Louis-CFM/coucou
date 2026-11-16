// File Shelf View — Staging dock for parked files and folders in Coucou's Desk.

import "./fileshelf.css";
import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { ShelfStore, type Shelf, type ShelfSort, type ParkedFile } from "../core/fileshelf";
import { Sound } from "../core/sound";
import { t } from "../i18n/i18n";
import type { ViewActions, ViewHost } from "./views";
import { dropdown } from "./dropdown";
import { Bridge, type FileShelfItemInfo } from "../core/bridge";

function tr(template: string, vars?: Record<string, string | number>): string {
  if (!vars) return template;
  return template.replace(/\{(\w+)\}/g, (_, k) => String(vars[k] ?? `{${k}}`));
}

export function buildFileShelf(_actions: ViewActions): ViewHost {
  let isSelectMode = false;
  const selectedFileIds = new Set<string>();
  let currentSort: ShelfSort = "recent";
  let isCreatingShelf = false;
  let renamingShelfId: string | null = null;
  let renamingFileId: string | null = null;
    let feedbackTimer: ReturnType<typeof setTimeout> | null = null;

  // ── Elements ──
  const shelfListEl = h("div", { class: "fileshelf-list" });
  const newShelfBtn = h("button", {
    class: "fileshelf-new-btn",
    type: "button",
    onclick: () => startCreateShelf(),
  }, svg(ICONS.plus, 11), h("span", { text: tr("New shelf") }));

  const sidebarEl = h("div", { class: "fileshelf-sidebar" },
    h("div", { class: "fileshelf-section-label", text: tr("SHELVES") }),
    shelfListEl,
    newShelfBtn,
  );

  const activeTitleEl = h("div", { class: "fileshelf-active-title" });
  const activeStatusEl = h("div", { class: "fileshelf-active-status" });
  const headerLeftEl = h("div", { class: "fileshelf-header-left" }, activeTitleEl, activeStatusEl);

  // Hidden file picker input for fallback when native dialog is unavailable
  const fileInput = h("input", {
    type: "file",
    multiple: "true",
    style: "display:none",
  }) as HTMLInputElement;

  fileInput.addEventListener("change", () => {
    if (fileInput.files && fileInput.files.length > 0) {
      void ingestFiles(Array.from(fileInput.files));
      fileInput.value = "";
    }
  });

  const sortTriggerLabelMap: Record<string, string> = {
    recent: t("Recent"),
    oldest: tr("Oldest"),
    name_asc: tr("Name A–Z"),
    name_desc: tr("Name Z–A"),
    size_desc: tr("Largest"),
    size_asc: tr("Smallest"),
    type: tr("Type"),
  };

  const sortLabelSpan = h("span", { text: t("Recent") });

  const openSortMenu = (anchor: HTMLElement) => {
    const sortMenu = dropdown([
      { label: tr("Recently added"), onClick: () => setSort("recent"), checked: currentSort === "recent" },
      { label: tr("Oldest added"), onClick: () => setSort("oldest"), checked: currentSort === "oldest" },
      { type: "separator" },
      { label: tr("Name (A–Z)"), onClick: () => setSort("name_asc"), checked: currentSort === "name_asc" || currentSort === "name" },
      { label: tr("Name (Z–A)"), onClick: () => setSort("name_desc"), checked: currentSort === "name_desc" },
      { type: "separator" },
      { label: tr("Largest first"), onClick: () => setSort("size_desc"), checked: currentSort === "size_desc" || currentSort === "size" },
      { label: tr("Smallest first"), onClick: () => setSort("size_asc"), checked: currentSort === "size_asc" },
      { type: "separator" },
      { label: tr("File type"), onClick: () => setSort("type"), checked: currentSort === "type" },
    ]);
    sortMenu.open(anchor);
  };

  const sortTrigger = h("button", {
    class: "fileshelf-tool-btn",
    type: "button",
    title: tr("Sort files"),
    onclick: (e) => openSortMenu(e.currentTarget as HTMLElement),
  }, sortLabelSpan, svg(ICONS.chevronDown, 9, { stroke: 2 }));

  const selectBtn = h("button", {
    class: "fileshelf-tool-btn",
    type: "button",
    title: tr("Select mode"),
    onclick: () => toggleSelectMode(),
  }, h("span", { text: tr("Select") }));

  // Prominent "Add Files" toolbar button: ALWAYS accessible in header
  const addFilesBtn = h("button", {
    class: "fileshelf-tool-btn fileshelf-add-btn",
    type: "button",
    title: tr("Add files to shelf"),
    onclick: () => void triggerAddFiles(),
  }, svg(ICONS.plus, 10), h("span", { text: tr("Add Files") }));

  const copyAllBtn = h("button", {
    class: "fileshelf-tool-btn ghost",
    type: "button",
    title: tr("Copy all paths"),
    onclick: () => handleCopyAll(),
  }, h("span", { text: tr("Copy all") }));

  const clearBtn = h("button", {
    class: "fileshelf-tool-btn ghost danger",
    type: "button",
    title: tr("Clear shelf"),
    onclick: () => handleClear(),
  }, h("span", { text: t("Clear") }));

  const toolbarGroup = h("div", { class: "fileshelf-toolbar-group" }, sortTrigger, selectBtn);
  const divider1 = h("div", { class: "fileshelf-toolbar-divider" });
  const divider2 = h("div", { class: "fileshelf-toolbar-divider" });

  const toolbarEl = h("div", { class: "fileshelf-toolbar" },
    toolbarGroup,
    divider1,
    addFilesBtn,
    divider2,
    copyAllBtn,
    clearBtn,
  );

  const headerEl = h("div", { class: "fileshelf-header" }, headerLeftEl, toolbarEl);
  const contentEl = h("div", { class: "fileshelf-content" });

  const feedbackToastEl = h("div", { class: "fileshelf-feedback-toast", style: "display:none" });

  const mainEl = h("div", { class: "fileshelf-main" }, headerEl, contentEl, feedbackToastEl);
  const cardEl = h("div", { class: "fileshelf-card" }, sidebarEl, mainEl, fileInput);
  const viewEl = h("div", { class: "view fileshelf-view" }, cardEl);

  // ── Functions ──

  function showFeedback(msg: string) {
        feedbackToastEl.textContent = msg;
    feedbackToastEl.style.display = "";
    if (feedbackTimer) clearTimeout(feedbackTimer);
    feedbackTimer = setTimeout(() => {
      feedbackToastEl.style.display = "none";
            feedbackTimer = null;
    }, 2800);
  }

  function setSort(sort: ShelfSort) {
    currentSort = sort;
    sortLabelSpan.textContent = sortTriggerLabelMap[sort] || t("Recent");
    Sound.resume();
    Sound.play("blip");
    render();
  }

  function toggleSelectMode() {
    isSelectMode = !isSelectMode;
    selectedFileIds.clear();
    selectBtn.classList.toggle("on", isSelectMode);
    Sound.resume();
    Sound.play("tick");
    render();
  }

  async function triggerAddFiles() {
    Sound.resume();
    Sound.play("tick");

    try {
      const paths = await Bridge.fileshelfPickFiles();
      if (paths && paths.length > 0) {
        // Query native file metadata
        const infos = await Bridge.fileshelfGetFileInfo(paths);
        const raw = (infos && infos.length > 0)
          ? infos.map((info: FileShelfItemInfo) => ({
              name: info.name,
              path: info.path,
              size: info.size,
              type: info.extension ? `file/${info.extension}` : "application/octet-stream",
            }))
          : paths.map((p: string) => {
              const name = p.split(/[\\/]/).pop() || p;
              return { name, path: p };
            });

        const activeShelf = ShelfStore.getActiveShelf();
        const res = ShelfStore.addFilesWithResult(activeShelf.id, raw);
        if (res.added.length > 0) {
          Sound.play("pop");
        }
        if (res.duplicates.length > 0) {
          showFeedback(tr("{count} duplicate(s) skipped", { count: res.duplicates.length }));
        } else if (res.added.length > 0) {
          showFeedback(tr("{count} file(s) added", { count: res.added.length }));
        }
        render();
        return;
      }
    } catch (err) {
      console.warn("[fileshelf] native picker failed, falling back to browser picker", err);
    }

    // Fallback if not running in Tauri or native picker cancelled
    fileInput.click();
  }

  async function openFile(file: ParkedFile) {
    if (!file.path) return;
    ShelfStore.updateFile(ShelfStore.getActiveShelfId(), file.id, { lastAccessedAt: Date.now() });

    try {
      await Bridge.fileshelfOpenFile(file.path);
      Sound.resume();
      Sound.play("blip");
    } catch (err) {
      console.warn("[fileshelf] open file failed", err);
      ShelfStore.updateFile(ShelfStore.getActiveShelfId(), file.id, { missing: true });
      showFeedback(tr("File not found on disk"));
      Sound.resume();
      Sound.play("tick");
      render();
    }
  }

  async function revealFile(file: ParkedFile) {
    if (!file.path) return;
    Sound.resume();
    Sound.play("blip");
    try {
      await Bridge.fileshelfRevealFile(file.path);
    } catch (err) {
      console.warn("[fileshelf] reveal file failed", err);
      showFeedback(tr("File not found on disk"));
    }
  }

  function copyFilePath(path: string) {
    if (typeof navigator !== "undefined" && navigator.clipboard) {
      void navigator.clipboard.writeText(path);
    }
    Sound.resume();
    Sound.play("approve");
    showFeedback(tr("Path copied to clipboard"));
  }

  function removeSingleFile(fileId: string) {
    const activeShelf = ShelfStore.getActiveShelf();
    ShelfStore.removeFile(activeShelf.id, fileId);
    selectedFileIds.delete(fileId);
    Sound.resume();
    Sound.play("tick");
    render();
  }

  function handleCopyAll() {
    const activeShelf = ShelfStore.getActiveShelf();
    if (activeShelf.files.length === 0) return;

    const paths = activeShelf.files.map((f) => f.path || f.name).join("\n");
    if (typeof navigator !== "undefined" && navigator.clipboard) {
      void navigator.clipboard.writeText(paths);
    }

    Sound.resume();
    Sound.play("approve");

    const originalText = copyAllBtn.textContent;
    copyAllBtn.textContent = `✓ ${t("Copied")}`;
    setTimeout(() => {
      copyAllBtn.textContent = originalText;
    }, 1400);
  }

  function handleClear() {
    const activeShelf = ShelfStore.getActiveShelf();
    if (activeShelf.files.length === 0) return;

    ShelfStore.clearShelf(activeShelf.id);
    selectedFileIds.clear();
    Sound.resume();
    Sound.play("tick");
    render();
  }

  function startCreateShelf() {
    if (isCreatingShelf) return;
    isCreatingShelf = true;

    const input = h("input", {
      class: "fileshelf-new-input",
      type: "text",
      placeholder: tr("Shelf name..."),
    }) as HTMLInputElement;

    const row = h("div", { class: "fileshelf-new-input-row" }, input);

    let finished = false;
    const finish = (commit: boolean) => {
      if (finished) return;
      finished = true;
      const val = input.value.trim();
      if (commit && val) {
        ShelfStore.createShelf(val);
        Sound.resume();
        Sound.play("pop");
      }
      isCreatingShelf = false;
      render();
    };

    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        finish(true);
      }
      if (e.key === "Escape") {
        e.preventDefault();
        finish(false);
      }
    });

    input.addEventListener("blur", () => finish(true));

    clear(sidebarEl);
    sidebarEl.append(
      h("div", { class: "fileshelf-section-label", text: tr("SHELVES") }),
      shelfListEl,
      row,
    );
    input.focus();
  }

  async function ingestFiles(files: File[]) {
    if (files.length === 0) return;
    const activeShelf = ShelfStore.getActiveShelf();

    // Check if files have native path
    const paths = files
      .map((f) => (f as unknown as { path?: string }).path)
      .filter((p): p is string => Boolean(p && p.trim()));

    if (paths.length === files.length) {
      try {
        const infos = await Bridge.fileshelfGetFileInfo(paths);
        if (infos && infos.length > 0) {
          const raw = infos.map((info: FileShelfItemInfo) => ({
            name: info.name,
            path: info.path,
            size: info.size,
            type: info.extension ? `file/${info.extension}` : "application/octet-stream",
          }));
          const res = ShelfStore.addFilesWithResult(activeShelf.id, raw);
          if (res.duplicates.length > 0) {
            showFeedback(tr("{count} duplicate(s) skipped", { count: res.duplicates.length }));
          } else {
            showFeedback(tr("{count} file(s) added", { count: res.added.length }));
          }
          Sound.resume();
          Sound.play("pop");
          render();
          return;
        }
      } catch {}
    }

    const raw = files.map((f) => ({
      name: f.name,
      path: (f as unknown as { path?: string }).path || f.name,
      size: f.size,
      type: f.type,
    }));
    const res = ShelfStore.addFilesWithResult(activeShelf.id, raw);
    if (res.duplicates.length > 0) {
      showFeedback(tr("{count} duplicate(s) skipped", { count: res.duplicates.length }));
    } else if (res.added.length > 0) {
      showFeedback(tr("{count} file(s) added", { count: res.added.length }));
    }
    Sound.resume();
    Sound.play("tick");
    render();
  }

  // ── Drag & Drop & Paste Listeners on entire view ──
  cardEl.addEventListener("dragover", (e) => {
    e.preventDefault();
    cardEl.classList.add("over");
  });

  cardEl.addEventListener("dragleave", (e) => {
    if (!cardEl.contains(e.relatedTarget as Node)) {
      cardEl.classList.remove("over");
    }
  });

  cardEl.addEventListener("drop", (e) => {
    e.preventDefault();
    cardEl.classList.remove("over");
    if (e.dataTransfer?.files && e.dataTransfer.files.length > 0) {
      void ingestFiles(Array.from(e.dataTransfer.files));
    }
  });

  // Paste handling (Ctrl+V)
  viewEl.addEventListener("paste", (e) => {
    if (e.clipboardData?.files && e.clipboardData.files.length > 0) {
      e.preventDefault();
      void ingestFiles(Array.from(e.clipboardData.files));
    }
  });

  // Comprehensive file icon renderer with semantic coloring
  function getFileIcon(ext: string): SVGSVGElement {
    const e = ext.toLowerCase();
    const isImage = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "tiff", "psd", "ai"].includes(e);
    const isPdf = e === "pdf";
    const isDoc = ["doc", "docx", "txt", "rtf", "odt", "md", "markdown", "tex", "log"].includes(e);
    const isSheet = ["xls", "xlsx", "csv", "tsv", "ods"].includes(e);
    const isSlide = ["ppt", "pptx", "key", "odp"].includes(e);
    const isCode = ["ts", "tsx", "js", "jsx", "py", "rs", "go", "c", "cpp", "h", "hpp", "cs", "java", "html", "css", "scss", "json", "xml", "yaml", "yml", "toml", "sql", "sh", "ps1", "bat"].includes(e);
    const isZip = ["zip", "tar", "gz", "rar", "7z", "bz2", "xz", "iso"].includes(e);
    const isMedia = ["mp3", "wav", "flac", "m4a", "ogg", "mp4", "mkv", "mov", "avi", "webm"].includes(e);
    const isExe = ["exe", "msi", "dll", "app", "apk"].includes(e);

    const svgEl = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svgEl.setAttribute("viewBox", "0 0 24 24");
    svgEl.setAttribute("fill", "none");
    svgEl.setAttribute("stroke", "currentColor");
    svgEl.setAttribute("stroke-width", "1.75");
    svgEl.setAttribute("stroke-linecap", "round");
    svgEl.setAttribute("stroke-linejoin", "round");

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    if (isImage) {
      path.setAttribute("d", "M4 6a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6zm4 5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3zm12 5-5-5-6 6");
      svgEl.style.stroke = "#38bdf8"; // Sky blue
    } else if (isPdf) {
      path.setAttribute("d", "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M9 15h6M9 11h6");
      svgEl.style.stroke = "#f43f5e"; // Rose / Red
    } else if (isDoc) {
      path.setAttribute("d", "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M8 13h8M8 17h6M8 9h2");
      svgEl.style.stroke = "#60a5fa"; // Blue
    } else if (isSheet) {
      path.setAttribute("d", "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M8 11h8M8 15h8M8 19h8M12 11v8");
      svgEl.style.stroke = "#10b981"; // Emerald
    } else if (isSlide) {
      path.setAttribute("d", "M3 4h18a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zm5 16l4-2 4 2M8 11l4-3 4 3");
      svgEl.style.stroke = "#f59e0b"; // Amber
    } else if (isCode) {
      path.setAttribute("d", "M16 18l6-6-6-6M8 6l-6 6 6 6");
      svgEl.style.stroke = "#34d399"; // Green
    } else if (isZip) {
      path.setAttribute("d", "M10 2v20M14 2v20M4 7h16M4 17h16");
      svgEl.style.stroke = "#fbbf24"; // Gold
    } else if (isMedia) {
      path.setAttribute("d", "M9 18V5l12-2v13M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0zm12-2a3 3 0 1 1-6 0 3 3 0 0 1 6 0z");
      svgEl.style.stroke = "#a855f7"; // Purple
    } else if (isExe) {
      path.setAttribute("d", "M4 4h16v16H4zM9 9h6v6H9z");
      svgEl.style.stroke = "#94a3b8"; // Slate
    } else {
      path.setAttribute("d", "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6");
      svgEl.style.stroke = "rgba(255, 255, 255, 0.75)";
    }
    svgEl.append(path);
    return svgEl;
  }

  function openShelfMenu(anchor: HTMLElement, shelf: Shelf) {
    anchor.classList.add("open");
    const items: Parameters<typeof dropdown>[0] = [
      {
        label: tr("Rename"),
        icon: "pencil",
        onClick: () => {
          anchor.classList.remove("open");
          renamingShelfId = shelf.id;
          render();
        },
      },
      {
        label: t("Clear"),
        icon: "x",
        onClick: () => {
          anchor.classList.remove("open");
          ShelfStore.clearShelf(shelf.id);
          Sound.resume();
          Sound.play("tick");
          render();
        },
      },
    ];

    if (!shelf.isDefault) {
      items.push({
        label: t("Delete"),
        icon: "trash",
        danger: true,
        onClick: () => {
          anchor.classList.remove("open");
          ShelfStore.deleteShelf(shelf.id);
          Sound.resume();
          Sound.play("pop");
          render();
        },
      });
    }

    const menu = dropdown(items);
    menu.open(anchor);
  }

  function openCardContextMenu(anchor: HTMLElement, file: ParkedFile) {
    const items: Parameters<typeof dropdown>[0] = [
      {
        label: tr("Open file"),
        onClick: () => void openFile(file),
      },
      {
        label: tr("Reveal in File Explorer"),
        onClick: () => void revealFile(file),
      },
      {
        label: tr("Copy path"),
        icon: "copy",
        onClick: () => copyFilePath(file.path || file.name),
      },
      {
        label: tr("Rename display name"),
        icon: "pencil",
        onClick: () => {
          renamingFileId = file.id;
          render();
        },
      },
      { type: "separator" },
      {
        label: tr("Remove from shelf"),
        icon: "trash",
        danger: true,
        onClick: () => removeSingleFile(file.id),
      },
    ];

    const menu = dropdown(items);
    menu.open(anchor);
  }

  // ── Render ──
  function render() {
    const shelves = ShelfStore.getShelves();
    const activeShelf = ShelfStore.getActiveShelf();

    // Render Shelves sidebar list
    clear(shelfListEl);
    for (const shelf of shelves) {
      const isActive = shelf.id === activeShelf.id;
      const count = shelf.files.length;
      const isRenaming = renamingShelfId === shelf.id;

      let nameContent: HTMLElement;
      if (isRenaming) {
        const renameInput = h("input", {
          class: "fileshelf-rename-input",
          type: "text",
          value: shelf.name,
        }) as HTMLInputElement;

        let renameDone = false;
        const finishRename = (commit: boolean) => {
          if (renameDone) return;
          renameDone = true;
          const val = renameInput.value.trim();
          if (commit && val && val !== shelf.name) {
            ShelfStore.renameShelf(shelf.id, val);
            Sound.resume();
            Sound.play("pop");
          }
          renamingShelfId = null;
          render();
        };

        renameInput.addEventListener("keydown", (e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            finishRename(true);
          }
          if (e.key === "Escape") {
            e.preventDefault();
            finishRename(false);
          }
        });
        renameInput.addEventListener("blur", () => finishRename(true));
        renameInput.addEventListener("click", (e) => e.stopPropagation());

        setTimeout(() => {
          renameInput.focus();
          renameInput.select();
        }, 10);

        nameContent = h("span", { class: "shelf-name" }, svg(ICONS.folder, 14), renameInput);
      } else {
        nameContent = h("span", { class: "shelf-name" }, svg(ICONS.folder, 14), h("span", { text: shelf.name }));
      }

      const countBadge = h("span", { class: "fileshelf-count-badge", text: String(count) });

      const moreBtn = h("button", {
        class: "fileshelf-shelf-more",
        type: "button",
        title: tr("Options"),
        onclick: (e) => {
          e.stopPropagation();
          openShelfMenu(moreBtn, shelf);
        },
      }, svg(ICONS.ellipsis, 12));

      const rightEl = h("div", { class: "fileshelf-shelf-right" }, countBadge, moreBtn);

      const btn = h("button", {
        class: `fileshelf-shelf-btn ${isActive ? "on" : ""}`,
        type: "button",
        onclick: () => {
          if (isRenaming) return;
          if (activeShelf.id !== shelf.id) {
            ShelfStore.setActiveShelfId(shelf.id);
            selectedFileIds.clear();
            Sound.resume();
            Sound.play("blip");
            render();
          }
        },
      }, nameContent, rightEl);

      shelfListEl.append(btn);
    }

    if (!isCreatingShelf) {
      clear(sidebarEl);
      sidebarEl.append(
        h("div", { class: "fileshelf-section-label", text: tr("SHELVES") }),
        shelfListEl,
        newShelfBtn
      );
    }

    // Active shelf header statistics
    activeTitleEl.textContent = activeShelf.name;
    const files = ShelfStore.getSortedFiles(activeShelf.id, currentSort);
    const totalBytes = files.reduce((acc, f) => acc + (f.size || 0), 0);

    if (files.length === 0) {
      activeStatusEl.textContent = tr("Empty");
      copyAllBtn.disabled = true;
      clearBtn.disabled = true;
    } else {
      activeStatusEl.textContent = `${files.length} ${files.length === 1 ? t("file") : t("files")} · ${ShelfStore.formatBytes(totalBytes)}`;
      copyAllBtn.disabled = false;
      clearBtn.disabled = false;
    }

    // Render Content (Empty dropzone or Populated Grid)
    clear(contentEl);

    if (files.length === 0) {
      const dropzone = h("div", {
        class: "fileshelf-dropzone",
        onclick: (e) => {
          if ((e.target as HTMLElement).tagName !== "BUTTON" && !(e.target as HTMLElement).closest("button")) {
            void triggerAddFiles();
          }
        },
      },
        h("div", { class: "fileshelf-empty-stack" },
          h("div", { class: "fileshelf-empty-icon-badge" }, svg(ICONS.folder, 16)),
          h("div", { class: "fileshelf-empty-copy" },
            h("div", {
              class: "fileshelf-empty-title",
              text: tr("Nothing on {name} yet", { name: activeShelf.name }),
            }),
            h("div", {
              class: "fileshelf-empty-sub",
              text: tr("Drop files here to stage them on this shelf"),
            }),
            h("div", {
              class: "fileshelf-empty-hint",
              text: tr("Paste files with Ctrl+V"),
            }),
          ),
          h("button", {
            class: "fileshelf-choose-btn",
            type: "button",
            onclick: (e) => {
              e.stopPropagation();
              void triggerAddFiles();
            },
          }, svg(ICONS.plus, 10), h("span", { text: tr("Add Files") }))
        )
      );

      dropzone.addEventListener("dragover", (e) => {
        e.preventDefault();
        dropzone.classList.add("over");
      });
      dropzone.addEventListener("dragleave", () => dropzone.classList.remove("over"));
      dropzone.addEventListener("drop", (e) => {
        e.preventDefault();
        dropzone.classList.remove("over");
        if (e.dataTransfer?.files && e.dataTransfer.files.length > 0) {
          void ingestFiles(Array.from(e.dataTransfer.files));
        }
      });

      contentEl.append(dropzone);
    } else {
      // Populated grid
      const grid = h("div", { class: "fileshelf-grid" });

      for (const f of files) {
        const isSelected = selectedFileIds.has(f.id);
        const isRenaming = renamingFileId === f.id;

        const card = h("div", {
          class: `fileshelf-file-card ${isSelected ? "selected" : ""} ${f.missing ? "missing" : ""}`,
          draggable: "true",
          title: f.path || f.name,
        });

        // Native drag out support
        card.addEventListener("dragstart", (e) => {
          if (e.dataTransfer) {
            e.dataTransfer.setData("text/plain", f.path || f.name);
          }
        });

        // Context menu (right click)
        card.addEventListener("contextmenu", (e) => {
          e.preventDefault();
          e.stopPropagation();
          openCardContextMenu(card, f);
        });

        // Select mode checkbox
        if (isSelectMode) {
          const cb = h("input", {
            type: "checkbox",
            class: "fileshelf-checkbox",
            checked: isSelected,
          }) as HTMLInputElement;

          cb.addEventListener("change", (e) => {
            e.stopPropagation();
            if (cb.checked) selectedFileIds.add(f.id);
            else selectedFileIds.delete(f.id);
            render();
          });
          card.append(cb);
        }

        // Hover quick action bar (Open, Reveal, Copy path, Remove)
        const openBtn = h("button", {
          class: "fileshelf-card-btn",
          title: tr("Open file"),
          type: "button",
          onclick: (e) => {
            e.stopPropagation();
            void openFile(f);
          },
        }, svg(ICONS.arrowUpRight, 9));

        const revealBtn = h("button", {
          class: "fileshelf-card-btn",
          title: tr("Reveal in File Explorer"),
          type: "button",
          onclick: (e) => {
            e.stopPropagation();
            void revealFile(f);
          },
        }, svg(ICONS.folder, 9));

        const copyBtn = h("button", {
          class: "fileshelf-card-btn",
          title: tr("Copy path"),
          type: "button",
          onclick: (e) => {
            e.stopPropagation();
            copyFilePath(f.path || f.name);
          },
        }, svg(ICONS.copy, 9));

        const deleteBtn = h("button", {
          class: "fileshelf-card-btn danger",
          title: tr("Remove from shelf"),
          type: "button",
          onclick: (e) => {
            e.stopPropagation();
            removeSingleFile(f.id);
          },
        }, svg(ICONS.xmark, 9));

        const actionsRow = h("div", { class: "fileshelf-card-actions" }, openBtn, revealBtn, copyBtn, deleteBtn);
        card.append(actionsRow);

        // File icon
        const iconWrap = h("div", { class: "fileshelf-file-icon" }, getFileIcon(f.extension));

        // File name (or inline rename input)
        let nameEl: HTMLElement;
        if (isRenaming) {
          const renameInput = h("input", {
            class: "fileshelf-card-rename-input",
            type: "text",
            value: f.name,
          }) as HTMLInputElement;

          let renameDone = false;
          const finishCardRename = (commit: boolean) => {
            if (renameDone) return;
            renameDone = true;
            const val = renameInput.value.trim();
            if (commit && val && val !== f.name) {
              ShelfStore.renameFile(activeShelf.id, f.id, val);
              Sound.resume();
              Sound.play("pop");
            }
            renamingFileId = null;
            render();
          };

          renameInput.addEventListener("keydown", (e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              finishCardRename(true);
            }
            if (e.key === "Escape") {
              e.preventDefault();
              finishCardRename(false);
            }
          });
          renameInput.addEventListener("blur", () => finishCardRename(true));
          renameInput.addEventListener("click", (e) => e.stopPropagation());

          setTimeout(() => {
            renameInput.focus();
            renameInput.select();
          }, 10);

          nameEl = h("div", { class: "fileshelf-file-name" }, renameInput);
        } else {
          nameEl = h("div", {
            class: "fileshelf-file-name",
            text: f.name,
          });
        }

        // Subtitle: Type · Size (or Missing)
        const sizeLabel = f.missing
          ? h("span", { class: "fileshelf-missing-badge", text: tr("Missing") })
          : h("span", { text: `${f.extension ? f.extension.toUpperCase() + " · " : ""}${ShelfStore.formatBytes(f.size)}` });

        const sizeEl = h("div", { class: "fileshelf-file-size" }, sizeLabel);

        card.append(iconWrap, nameEl, sizeEl);

        // Click handler: in select mode toggles selection; otherwise double-click opens, single-click selects or copies
        card.addEventListener("click", (e) => {
          if (isSelectMode) {
            e.stopPropagation();
            if (selectedFileIds.has(f.id)) selectedFileIds.delete(f.id);
            else selectedFileIds.add(f.id);
            render();
          }
        });

        card.addEventListener("dblclick", (e) => {
          e.stopPropagation();
          void openFile(f);
        });

        grid.append(card);
      }

      contentEl.append(grid);

      // In select mode: batch action toolbar at bottom
      if (isSelectMode) {
        const allSelected = files.length > 0 && selectedFileIds.size === files.length;
        const toggleAllBtn = h("button", {
          class: "fileshelf-batch-link",
          type: "button",
          text: allSelected ? tr("Deselect all") : tr("Select all"),
          onclick: () => {
            if (allSelected) {
              selectedFileIds.clear();
            } else {
              for (const f of files) selectedFileIds.add(f.id);
            }
            render();
          },
        });

        const batchCopyBtn = h("button", {
          class: "fileshelf-batch-btn",
          type: "button",
          disabled: selectedFileIds.size === 0,
          text: tr("Copy paths ({count})", { count: selectedFileIds.size }),
          onclick: () => {
            const selectedFiles = files.filter((f) => selectedFileIds.has(f.id));
            const paths = selectedFiles.map((f) => f.path || f.name).join("\n");
            copyFilePath(paths);
          },
        });

        const batchDeleteBtn = h("button", {
          class: "fileshelf-batch-btn danger",
          type: "button",
          disabled: selectedFileIds.size === 0,
          text: tr("Remove ({count})", { count: selectedFileIds.size }),
          onclick: () => {
            ShelfStore.removeFiles(activeShelf.id, Array.from(selectedFileIds));
            selectedFileIds.clear();
            Sound.resume();
            Sound.play("tick");
            render();
          },
        });

        const batchBar = h("div", { class: "fileshelf-batch-bar" },
          h("div", { style: "display:flex;align-items:center;gap:10px" },
            h("span", { class: "fileshelf-batch-count", text: tr("{count} selected", { count: selectedFileIds.size }) }),
            toggleAllBtn,
          ),
          h("div", { style: "display:flex;gap:6px" }, batchCopyBtn, batchDeleteBtn)
        );
        contentEl.append(batchBar);
      }
    }
  }

  // Reactive subscription
  ShelfStore.subscribe(() => {
    if (viewEl.classList.contains("on")) {
      render();
    }
  });

  return {
    el: viewEl,
    sync() {
      render();
    },
    focus() {
      render();
    },
  };
}

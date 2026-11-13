// File Shelf View — Staging dock for parked files and folders in Coucou's notch.

import "./fileshelf.css";
import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { ShelfStore, type Shelf, type ShelfSort } from "../core/fileshelf";
import { Sound } from "../core/sound";
import { t } from "../i18n/i18n";
import type { ViewActions, ViewHost } from "./views";
import { dropdown } from "./dropdown";

function tr(template: string, vars?: Record<string, string | number>): string {
  if (!vars) return template;
  return template.replace(/\{(\w+)\}/g, (_, k) => String(vars[k] ?? `{${k}}`));
}

export function buildFileShelf(_actions: ViewActions): ViewHost {
  let isSelectMode = false;
  let selectedFileIds = new Set<string>();
  let currentSort: ShelfSort = "recent";
  let isCreatingShelf = false;
  let renamingShelfId: string | null = null;

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

  const activeTitleEl = h("span", { class: "fileshelf-active-title" });
  const activeStatusEl = h("span", { class: "fileshelf-active-status" });
  const headerLeftEl = h("div", { class: "fileshelf-header-left" }, activeTitleEl, activeStatusEl);

  // Hidden file picker input for "Choose files" button
  const fileInput = h("input", {
    type: "file",
    multiple: "true",
    style: "display:none",
  }) as HTMLInputElement;

  fileInput.addEventListener("change", () => {
    if (fileInput.files && fileInput.files.length > 0) {
      ingestFiles(Array.from(fileInput.files));
      fileInput.value = "";
    }
  });

  const sortLabelMap: Record<ShelfSort, string> = {
    recent: t("Recent"),
    name: tr("Name (A-Z)"),
    size: tr("Size"),
    type: tr("Type"),
  };

  const sortLabelSpan = h("span", { text: t("Recent") });

  const openSortMenu = (anchor: HTMLElement) => {
    const sortMenu = dropdown([
      { label: t("Recent"), onClick: () => setSort("recent"), checked: currentSort === "recent" },
      { label: tr("Name (A-Z)"), onClick: () => setSort("name"), checked: currentSort === "name" },
      { label: tr("Size"), onClick: () => setSort("size"), checked: currentSort === "size" },
      { label: tr("Type"), onClick: () => setSort("type"), checked: currentSort === "type" },
    ]);
    sortMenu.open(anchor);
  };

  const recentTrigger = h("button", {
    class: "fileshelf-tool-btn",
    type: "button",
    onclick: (e) => openSortMenu(e.currentTarget as HTMLElement),
  }, sortLabelSpan, svg(ICONS.chevronDown, 9, { stroke: 2 }));

  const selectBtn = h("button", {
    class: "fileshelf-tool-btn",
    type: "button",
    onclick: () => toggleSelectMode(),
  }, h("span", { text: tr("Select") }));

  const copyAllBtn = h("button", {
    class: "fileshelf-tool-btn",
    type: "button",
    onclick: () => handleCopyAll(),
  }, h("span", { text: tr("Copy all") }));

  const clearBtn = h("button", {
    class: "fileshelf-tool-btn",
    type: "button",
    onclick: () => handleClear(),
  }, h("span", { text: t("Clear") }));

  const toolbarEl = h("div", { class: "fileshelf-toolbar" },
    recentTrigger,
    selectBtn,
    copyAllBtn,
    clearBtn,
  );

  const headerEl = h("div", { class: "fileshelf-header" }, headerLeftEl, toolbarEl);
  const contentEl = h("div", { class: "fileshelf-content" });

  const mainEl = h("div", { class: "fileshelf-main" }, headerEl, contentEl);
  const cardEl = h("div", { class: "fileshelf-card" }, sidebarEl, mainEl, fileInput);
  const viewEl = h("div", { class: "view fileshelf-view" }, cardEl);

  // ── Functions ──

  function setSort(sort: ShelfSort) {
    currentSort = sort;
    sortLabelSpan.textContent = sort === "recent" ? t("Recent") : sortLabelMap[sort] || t("Recent");
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

  function ingestFiles(files: File[]) {
    if (files.length === 0) return;
    const activeShelf = ShelfStore.getActiveShelf();
    const raw = files.map((f) => ({
      name: f.name,
      path: (f as unknown as { path?: string }).path || f.name,
      size: f.size,
      type: f.type,
    }));
    ShelfStore.addFiles(activeShelf.id, raw);
    Sound.resume();
    Sound.play("tick");
    render();
  }

  // ── Drag & Drop & Paste Listeners ──
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
      ingestFiles(Array.from(e.dataTransfer.files));
    }
  });

  // Paste handling (Ctrl+V)
  viewEl.addEventListener("paste", (e) => {
    if (e.clipboardData?.files && e.clipboardData.files.length > 0) {
      e.preventDefault();
      ingestFiles(Array.from(e.clipboardData.files));
    }
  });

  function getFileIcon(ext: string): SVGSVGElement {
    const isImage = ["png", "jpg", "jpeg", "gif", "webp", "svg"].includes(ext);
    const isCode = ["ts", "js", "py", "rs", "json", "html", "css", "c", "cpp", "go"].includes(ext);
    const isPdf = ext === "pdf";
    const isZip = ["zip", "tar", "gz", "rar", "7z"].includes(ext);

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
      svgEl.style.stroke = "#38bdf8";
    } else if (isPdf) {
      path.setAttribute("d", "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M9 15h6M9 11h6");
      svgEl.style.stroke = "#f43f5e";
    } else if (isCode) {
      path.setAttribute("d", "M16 18l6-6-6-6M8 6l-6 6 6 6");
      svgEl.style.stroke = "#34d399";
    } else if (isZip) {
      path.setAttribute("d", "M10 2v20M14 2v20M4 7h16M4 17h16");
      svgEl.style.stroke = "#fbbf24";
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

  // ── Render ──
  function render() {
    const shelves = ShelfStore.getShelves();
    const activeShelf = ShelfStore.getActiveShelf();

    // Render Shelves list
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

    // Active shelf header info
    activeTitleEl.textContent = activeShelf.name;
    const files = ShelfStore.getSortedFiles(activeShelf.id, currentSort);
    const totalBytes = files.reduce((acc, f) => acc + f.size, 0);

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
          // If clicked choose files or empty area, open file dialog
          if ((e.target as HTMLElement).tagName !== "BUTTON") {
            fileInput.click();
          }
        },
      },
        h("div", { class: "fileshelf-dropzone-row" },
          svg(ICONS.folder, 16),
          h("span", {
            class: "fileshelf-dropzone-text",
            text: tr("Nothing on {name} yet · drop files or paste with Ctrl+V", { name: activeShelf.name }),
          }),
          h("button", {
            class: "fileshelf-choose-btn",
            type: "button",
            onclick: (e) => {
              e.stopPropagation();
              fileInput.click();
            },
            text: tr("Choose files"),
          })
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
          ingestFiles(Array.from(e.dataTransfer.files));
        }
      });

      contentEl.append(dropzone);
    } else {
      // Populated grid
      const grid = h("div", { class: "fileshelf-grid" });

      for (const f of files) {
        const isSelected = selectedFileIds.has(f.id);

        const card = h("div", {
          class: `fileshelf-file-card ${isSelected ? "selected" : ""}`,
          draggable: "true",
        });

        // Native drag out
        card.addEventListener("dragstart", (e) => {
          if (e.dataTransfer) {
            e.dataTransfer.setData("text/plain", f.path || f.name);
          }
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

        // Hover quick actions (Remove, Copy path)
        const deleteBtn = h("button", {
          class: "fileshelf-card-btn",
          title: tr("Remove from shelf"),
          type: "button",
          onclick: (e) => {
            e.stopPropagation();
            ShelfStore.removeFile(activeShelf.id, f.id);
            Sound.resume();
            Sound.play("tick");
            render();
          },
        }, svg(ICONS.xmark, 9));

        const copyBtn = h("button", {
          class: "fileshelf-card-btn",
          title: tr("Copy path"),
          type: "button",
          onclick: (e) => {
            e.stopPropagation();
            if (typeof navigator !== "undefined" && navigator.clipboard) {
              void navigator.clipboard.writeText(f.path || f.name);
            }
            Sound.resume();
            Sound.play("approve");
          },
        }, svg(ICONS.copy, 9));

        const actionsRow = h("div", { class: "fileshelf-card-actions" }, copyBtn, deleteBtn);
        card.append(actionsRow);

        // Icon, Name, Size
        const iconWrap = h("div", { class: "fileshelf-file-icon" }, getFileIcon(f.extension));
        const nameEl = h("div", {
          class: "fileshelf-file-name",
          text: f.name,
          title: f.path || f.name,
        });
        const sizeEl = h("div", {
          class: "fileshelf-file-size",
          text: `${f.extension ? f.extension.toUpperCase() + " · " : ""}${ShelfStore.formatBytes(f.size)}`,
        });

        card.append(iconWrap, nameEl, sizeEl);

        card.addEventListener("click", () => {
          if (isSelectMode) {
            if (selectedFileIds.has(f.id)) selectedFileIds.delete(f.id);
            else selectedFileIds.add(f.id);
            render();
          } else {
            // Copy path by default on click
            if (typeof navigator !== "undefined" && navigator.clipboard) {
              void navigator.clipboard.writeText(f.path || f.name);
            }
            Sound.resume();
            Sound.play("tick");
          }
        });

        grid.append(card);
      }

      contentEl.append(grid);

      // In select mode: batch action toolbar
      if (isSelectMode && selectedFileIds.size > 0) {
        const batchDeleteBtn = h("button", {
          class: "fileshelf-batch-btn danger",
          type: "button",
          text: tr("Delete selected ({count})", { count: selectedFileIds.size }),
          onclick: () => {
            ShelfStore.removeFiles(activeShelf.id, Array.from(selectedFileIds));
            selectedFileIds.clear();
            Sound.resume();
            Sound.play("tick");
            render();
          },
        });

        const batchCopyBtn = h("button", {
          class: "fileshelf-batch-btn",
          type: "button",
          text: tr("Copy paths ({count})", { count: selectedFileIds.size }),
          onclick: () => {
            const selectedFiles = files.filter((f) => selectedFileIds.has(f.id));
            const paths = selectedFiles.map((f) => f.path || f.name).join("\n");
            if (typeof navigator !== "undefined" && navigator.clipboard) {
              void navigator.clipboard.writeText(paths);
            }
            Sound.resume();
            Sound.play("approve");
          },
        });

        const batchBar = h("div", { class: "fileshelf-batch-bar" },
          h("span", { text: tr("{count} selected", { count: selectedFileIds.size }) }),
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

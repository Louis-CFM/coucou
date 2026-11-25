// Coucou Clipboard — minimalist macOS-inspired clipboard productivity experience.
// Clean two-panel layout, cohesive segmented control with jelly spring indicator,
// quiet sidebar cards, aspect-contained image preview, and anchored Liquid Glass dropdown menus.

import "./clipboard.css";
import { h, svg } from "./dom";
import { ICONS } from "./icons";
import { dropdown } from "./dropdown";
import { animate, MACOS_JELLY } from "../hub/motion";
import { Bridge, type ClipboardItem, type ImageDataResult, onEvent } from "../core/bridge";
import { t } from "../i18n/i18n";
import type { ViewActions, ViewHost } from "./views";

type Category = "all" | "text" | "image" | "link";

interface LocalState {
  items: ClipboardItem[];
  category: Category;
  query: string;
  selectedId: string | null;
  monitoring: boolean;
  copyFeedback: string | null;
  loading: boolean;
}

// In-memory cache for decoded image data URLs
const imageCache = new Map<string, ImageDataResult>();

function relTime(ms: number): string {
  const diff = Math.max(0, Date.now() - ms);
  if (diff < 60_000) return t("just now");
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
}

function isToday(ms: number): boolean {
  const d = new Date(ms);
  const now = new Date();
  return d.getDate() === now.getDate() && d.getMonth() === now.getMonth() && d.getFullYear() === now.getFullYear();
}

function isYesterday(ms: number): boolean {
  const d = new Date(ms);
  const y = new Date();
  y.setDate(y.getDate() - 1);
  return d.getDate() === y.getDate() && d.getMonth() === y.getMonth() && d.getFullYear() === y.getFullYear();
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function cleanPreview(item: ClipboardItem): string {
  if (item.kind === "image") {
    return item.preview || `Image ${item.imageWidth ?? 0}×${item.imageHeight ?? 0}`;
  }
  if (item.kind === "link") {
    return item.preview || item.content;
  }
  const firstLine = item.content.split("\n").find((l) => l.trim().length > 0) || item.preview || item.content;
  return firstLine.replace(/^#+\s*/, "").trim();
}

function isCodeSnippet(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.length < 15) return false;
  const codePatterns = [
    /\b(const|let|var|function|return|import|export|class|interface|type|async|await)\b/,
    /\b(def|elif|import|from|class|lambda|self)\b/,
    /\b(fn|pub|struct|impl|mut|match|enum|use)\b/,
    /[{}();=>]{3,}/,
    /^(<[a-z][\s\S]*>[\s\S]*<\/[a-z]>|<[a-z][\s\S]*\/>)$/i,
    /\b(SELECT|FROM|WHERE|INSERT|UPDATE|DELETE)\b/i,
  ];
  return codePatterns.some((pattern) => pattern.test(trimmed));
}

function filterItems(items: ClipboardItem[], cat: Category, query: string): ClipboardItem[] {
  let result = items;
  if (cat !== "all") {
    result = result.filter((i) => i.kind === cat);
  }
  if (query.trim()) {
    const q = query.toLowerCase();
    result = result.filter(
      (i) => i.content.toLowerCase().includes(q) || i.preview.toLowerCase().includes(q),
    );
  }
  return result;
}

function countByKind(items: ClipboardItem[], kind: string): number {
  return items.filter((i) => i.kind === kind).length;
}

export function buildClipboard(actions: ViewActions): ViewHost {
  const state: LocalState = {
    items: [],
    category: "all",
    query: "",
    selectedId: null,
    monitoring: true,
    copyFeedback: null,
    loading: true,
  };

  let currentViewMode: "loading" | "paused" | "empty" | "populated" | null = null;
  let activeIndicatorAnimation: { stop: () => void } | null = null;
  let renderedPreviewId: string | null = null;

  // ── Root container ─────────────────────────────────────────────────────────
  const root = h("div", { class: "view clipboard-view" });

  // ── Populated two-column layout (mounted persistently) ────────────────────
  const populatedLayout = h("div", { class: "cb-populated-layout" });
  const leftCol = h("div", { class: "clipboard-left" });
  const rightCol = h("div", { class: "clipboard-right" });

  // Minimal Header (Icon + Title + Muted Count Badge only)
  const headerRow = h("div", { class: "clipboard-header-row" });
  const titleEl = h("div", { class: "clipboard-title" });
  headerRow.append(titleEl);

  // Segmented category control with sliding indicator
  const segmentedBar = h("div", { class: "cb-segmented-bar border-2" });
  const indicator = h("div", { class: "cb-segment-indicator" });
  segmentedBar.append(indicator);

  const cats: Category[] = ["all", "text", "image", "link"];
  const labels: Record<Category, string> = {
    all: t("All"),
    text: t("Text"),
    image: t("Images"),
    link: t("Links"),
  };

  const segmentButtons = new Map<Category, { btn: HTMLButtonElement; countSpan: HTMLElement }>();

  for (const cat of cats) {
    const countSpan = h("span", { class: "cb-segment-count" }, "0");
    const btn = h(
      "button",
      {
        class: `cb-segment ${state.category === cat ? "active" : ""}`,
        onclick: () => {
          if (state.category === cat) return;
          state.category = cat;
          updateActiveSegment();
          // Jelly-smooth cross-fade on history cards
          animate(historyList, { opacity: [0.65, 1], y: [2, 0] }, { duration: 0.12, ease: "easeOut" });
          renderHistory();
        },
      },
      h("span", { class: "cb-segment-label" }, labels[cat]),
      countSpan,
    ) as HTMLButtonElement;
    segmentedBar.append(btn);
    segmentButtons.set(cat, { btn, countSpan });
  }

  // Compact search input with border-2 token
  const searchWrap = h("div", { class: "cb-search-wrap" });
  const searchIcon = h("div", { class: "cb-search-icon" }, svg(ICONS.magnifier, 12));
  const searchInput = h("input", {
    class: "cb-search-input border-2",
    type: "text",
    placeholder: t("Search clipboard…"),
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;
  const searchClear = h("button", {
    class: "cb-search-clear-btn",
    title: t("Clear search"),
    onclick: () => {
      state.query = "";
      searchInput.value = "";
      searchClear.style.display = "none";
      renderHistory();
      updateSegmentCounts();
    },
  }, svg(ICONS.xmark, 11));
  searchClear.style.display = "none";

  searchInput.addEventListener("input", () => {
    state.query = searchInput.value;
    searchClear.style.display = state.query ? "flex" : "none";
    renderHistory();
  });
  searchInput.addEventListener("keydown", (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      state.query = "";
      searchInput.value = "";
      searchClear.style.display = "none";
      searchInput.blur();
      renderHistory();
    }
  });
  searchWrap.append(searchIcon, searchInput, searchClear);

  // History list container
  const historyList = h("div", { class: "clipboard-list" });
  leftCol.append(headerRow, segmentedBar, searchWrap, historyList);

  // Right preview panel
  const previewPanel = h("div", { class: "clipboard-preview" });
  rightCol.append(previewPanel);
  populatedLayout.append(leftCol, rightCol);

  // ── Context Menu (Coucou Dropdown Component with Pin Icon & Spacing) ─────
  function showItemContextMenu(item: ClipboardItem, anchor: HTMLElement) {
    const isPinned = item.pinned;
    const menu = dropdown(
      [
        {
          label: t("Copy"),
          icon: "copy",
          onClick: async () => {
            const result = await Bridge.clipboardCopyItem(item.id);
            if (result?.ok) {
              actions.blip();
              state.copyFeedback = "Copied ✓";
              renderPreviewFooter(item, imageCache.get(item.id));
              setTimeout(() => {
                state.copyFeedback = null;
                renderPreviewFooter(item, imageCache.get(item.id));
              }, 1500);
            }
          },
        },
        {
          label: isPinned ? t("Unpin") : t("Pin"),
          icon: "pin",
          onClick: async () => {
            await Bridge.clipboardPinItem(item.id, !isPinned);
            await loadHistory();
            renderAll();
          },
        },
        ...(item.kind === "link"
          ? [
              {
                label: t("Open in Browser"),
                icon: "sliders",
                onClick: () => actions.openUrl(item.content),
              },
            ]
          : []),
        { type: "separator" as const },
        {
          label: t("Delete"),
          icon: "trash",
          danger: true,
          onClick: async () => {
            await Bridge.clipboardDeleteItem(item.id);
            if (state.selectedId === item.id) {
              state.selectedId = null;
            }
            await loadHistory();
            renderAll();
          },
        },
      ],
      {
        className: "cb-dropdown-menu",
        minWidth: 144,
        maxWidth: 180,
        matchAnchorWidth: false,
      },
    );
    menu.open(anchor);
  }

  // ── Empty State Elements ──────────────────────────────────────────────────
  const emptyCanvas = h("div", { class: "cb-empty-canvas" });

  function buildEmptyState(): HTMLElement {
    const badge = h("div", { class: "cb-empty-badge" }, svg(ICONS.stack, 22));
    const title = h("div", { class: "cb-empty-title" }, t("Your clipboard, ready when you are."));
    const desc = h(
      "div",
      { class: "cb-empty-desc" },
      t("Copy anything to get started. Your copied text, images and links will appear here, ready to reuse whenever you need them."),
    );

    const hintText = h("div", { class: "cb-hint-pill" }, svg(ICONS.doc, 13), h("span", { text: t("Text") }));
    const hintImage = h("div", { class: "cb-hint-pill" }, svg(ICONS.eye, 13), h("span", { text: t("Images") }));
    const hintLink = h("div", { class: "cb-hint-pill" }, svg(ICONS.arrowUpRight, 13), h("span", { text: t("Links") }));
    const hintsRow = h("div", { class: "cb-empty-hints" }, hintText, hintImage, hintLink);

    const wrap = h("div", { class: "cb-empty-inner" }, badge, title, desc, hintsRow);
    emptyCanvas.innerHTML = "";
    emptyCanvas.append(wrap);
    return emptyCanvas;
  }

  function buildPausedState(): HTMLElement {
    const badge = h("div", { class: "cb-empty-badge cb-paused-badge" }, svg(ICONS.eye, 22));
    const title = h("div", { class: "cb-empty-title" }, t("Clipboard monitoring is paused"));
    const desc = h("div", { class: "cb-empty-desc" }, t("Coucou is not currently capturing copied items."));
    const resumeBtn = h(
      "button",
      {
        class: "cb-resume-btn",
        onclick: async () => {
          state.monitoring = true;
          await Bridge.clipboardSetMonitoring(true);
          renderAll();
        },
      },
      svg(ICONS.eye, 14),
      h("span", { text: t("Resume Monitoring") }),
    );

    const wrap = h("div", { class: "cb-empty-inner" }, badge, title, desc, resumeBtn);
    emptyCanvas.innerHTML = "";
    emptyCanvas.append(wrap);
    return emptyCanvas;
  }

  function buildLoadingState(): HTMLElement {
    const badge = h("div", { class: "cb-empty-badge cb-loading-badge" }, svg(ICONS.stack, 22));
    const wrap = h("div", { class: "cb-empty-inner" }, badge);
    emptyCanvas.innerHTML = "";
    emptyCanvas.append(wrap);
    return emptyCanvas;
  }

  // ── Render Functions ───────────────────────────────────────────────────────

  function renderTitle() {
    const count = state.items.length;
    titleEl.innerHTML = "";
    titleEl.append(
      svg(ICONS.stack, 13),
      h("span", { class: "cb-title-name" }, "Clipboard"),
      h("span", { class: "cb-title-badge" }, `${count} item${count !== 1 ? "s" : ""}`),
    );
  }

  function updateSegmentCounts() {
    const all = state.items;
    const counts: Record<Category, number> = {
      all: all.length,
      text: countByKind(all, "text"),
      image: countByKind(all, "image"),
      link: countByKind(all, "link"),
    };
    for (const cat of cats) {
      const entry = segmentButtons.get(cat);
      if (entry) {
        entry.countSpan.textContent = String(counts[cat]);
      }
    }
  }

  function updateActiveSegment(immediate = false) {
    for (const [cat, entry] of segmentButtons.entries()) {
      entry.btn.classList.toggle("active", cat === state.category);
    }
    const activeEntry = segmentButtons.get(state.category);
    if (!activeEntry) return;

    const targetX = activeEntry.btn.offsetLeft;
    const targetW = activeEntry.btn.offsetWidth;

    if (targetW === 0) {
      // Bar not yet measured in layout; retry on next frame
      requestAnimationFrame(() => updateActiveSegment(true));
      return;
    }

    if (immediate) {
      indicator.style.transform = `translateX(${targetX}px)`;
      indicator.style.width = `${targetW}px`;
    } else {
      if (activeIndicatorAnimation?.stop) {
        activeIndicatorAnimation.stop();
      }
      activeIndicatorAnimation = animate(
        indicator,
        {
          x: targetX,
          width: targetW,
        },
        MACOS_JELLY.indicator,
      );
    }
  }

  function renderHistory() {
    historyList.innerHTML = "";
    const visible = filterItems(state.items, state.category, state.query);

    if (visible.length === 0) {
      const noResults = h(
        "div",
        { class: "cb-no-results" },
        h("div", { class: "cb-no-results-title" }, t("No matching clipboard items")),
        h(
          "button",
          {
            class: "cb-clear-search-btn",
            onclick: () => {
              state.query = "";
              searchInput.value = "";
              searchClear.style.display = "none";
              renderHistory();
              updateSegmentCounts();
            },
          },
          t("Clear search"),
        ),
      );
      historyList.append(noResults);
      return;
    }

    // Partition into strict 4-tier date groups
    const pinned = visible.filter((i) => i.pinned);
    const today = visible.filter((i) => !i.pinned && isToday(i.lastCopiedAt));
    const yesterday = visible.filter((i) => !i.pinned && !isToday(i.lastCopiedAt) && isYesterday(i.lastCopiedAt));
    const previous = visible.filter((i) => !i.pinned && !isToday(i.lastCopiedAt) && !isYesterday(i.lastCopiedAt));

    function renderSection(label: string, items: ClipboardItem[]) {
      if (items.length === 0) return;
      const sec = h("div", { class: "cb-section" });
      const hdr = h("div", { class: "cb-section-label" }, label);
      sec.append(hdr);
      for (const item of items) {
        sec.append(renderCard(item));
      }
      historyList.append(sec);
    }

    renderSection(t("Pinned"), pinned);
    renderSection(t("Today"), today);
    renderSection(t("Yesterday"), yesterday);
    renderSection(t("Previous days"), previous);
  }

  function renderCard(item: ClipboardItem): HTMLElement {
    const isSelected = item.id === state.selectedId;
    const card = h("div", {
      class: `cb-card ${isSelected ? "selected" : ""}`,
      "data-id": item.id,
      onclick: () => {
        if (state.selectedId === item.id) return;
        // Zero-flicker selection: update selected classes without DOM wiping
        const prevSelected = historyList.querySelector(".cb-card.selected");
        if (prevSelected) prevSelected.classList.remove("selected");
        card.classList.add("selected");
        state.selectedId = item.id;
        renderPreview();
      },
      draggable: "true",
    });

    // Right-click anchored dropdown context menu
    card.addEventListener("contextmenu", (e: MouseEvent) => {
      e.preventDefault();
      showItemContextMenu(item, card);
    });

    // Native Drag and Drop
    card.addEventListener("dragstart", (e: DragEvent) => {
      if (!e.dataTransfer) return;
      if (item.kind === "image" && item.imagePath) {
        e.dataTransfer.setData("text/plain", item.imagePath);
        e.dataTransfer.effectAllowed = "copy";
      } else {
        e.dataTransfer.setData("text/plain", item.content);
        if (item.kind === "link") {
          e.dataTransfer.setData("text/uri-list", item.content);
          e.dataTransfer.setData("text/html", `<a href="${item.content}">${item.content}</a>`);
        }
        e.dataTransfer.effectAllowed = "copyMove";
      }
    });

    // Icon / Thumbnail
    let iconEl: HTMLElement;
    if (item.kind === "image") {
      iconEl = h("div", { class: "cb-card-thumb-wrap" });
      const cached = imageCache.get(item.id);
      if (cached) {
        const miniImg = h("img", {
          class: "cb-card-thumb-img",
          src: cached.dataUrl,
          alt: "Thumbnail",
        });
        iconEl.append(miniImg);
      } else {
        iconEl.append(svg(ICONS.eye, 12));
        void Bridge.clipboardGetImageData(item.id).then((res) => {
          if (res) {
            imageCache.set(item.id, res);
            iconEl.innerHTML = "";
            iconEl.append(h("img", { class: "cb-card-thumb-img", src: res.dataUrl, alt: "Thumbnail" }));
          }
        });
      }
    } else if (item.kind === "link") {
      iconEl = h("div", { class: "cb-card-icon-pill link" }, svg(ICONS.arrowUpRight, 12));
    } else {
      iconEl = h("div", { class: "cb-card-icon-pill text" }, svg(ICONS.doc, 12));
    }

    // Body: Preview title + Relative timestamp ONLY (minimal, clean)
    const body = h("div", { class: "cb-card-body" });
    const excerpt = cleanPreview(item);
    const previewEl = h("div", { class: "cb-card-preview" }, excerpt);
    const metaEl = h("div", { class: "cb-card-meta" }, relTime(item.lastCopiedAt));
    body.append(previewEl, metaEl);

    card.append(iconEl, body);
    if (item.pinned) {
      const pinMark = h("div", { class: "cb-card-pin", title: t("Pinned") }, svg(ICONS.star, 11));
      card.append(pinMark);
    }
    return card;
  }

  function renderPreview() {
    const item = state.items.find((i) => i.id === state.selectedId);
    if (!item) {
      renderedPreviewId = null;
      previewPanel.innerHTML = "";
      const empty = h(
        "div",
        { class: "cb-preview-empty" },
        h("div", { class: "cb-empty-icon" }, svg(ICONS.stack, 24)),
        h("div", { class: "cb-empty-title" }, "Select an item"),
        h("div", { class: "cb-empty-sub" }, "Pick a clipboard entry from the list to preview it."),
      );
      previewPanel.append(empty);
      return;
    }

    // If already showing this item, only refresh footer and header active state to eliminate flicker
    if (renderedPreviewId === item.id) {
      const pinBtn = previewPanel.querySelector(".cb-icon-btn");
      if (pinBtn) {
        pinBtn.classList.toggle("active", Boolean(item.pinned));
        pinBtn.setAttribute("title", item.pinned ? t("Unpin") : t("Pin"));
      }
      renderPreviewFooter(item, imageCache.get(item.id));
      return;
    }

    renderedPreviewId = item.id;
    previewPanel.innerHTML = "";

    // ── Preview Header: Clean typography without background pill ──────────────
    const ph = h("div", { class: "cb-preview-header" });
    const badgeLabel = item.kind === "image" ? t("Images") : item.kind === "link" ? t("Links") : t("Text");
    const badge = h("span", { class: `cb-badge cb-badge-${item.kind}` }, badgeLabel);
    const ts = h("span", { class: "cb-preview-ts" }, relTime(item.lastCopiedAt));

    const pinBtn = h(
      "button",
      {
        class: `cb-icon-btn ${item.pinned ? "active" : ""}`,
        title: item.pinned ? t("Unpin") : t("Pin"),
        onclick: async () => {
          await Bridge.clipboardPinItem(item.id, !item.pinned);
          await loadHistory();
          renderAll();
        },
      },
      svg(ICONS.star, 14),
    );

    ph.append(badge, ts, pinBtn);

    // ── Preview Body: Dedicated Renderers ─────────────────────────────────────
    const pb = h("div", { class: "cb-preview-body" });

    if (item.kind === "image") {
      // Clean Image Preview (Centered, stable aspect ratio)
      const imgContainer = h("div", { class: "cb-image-preview-wrap" });
      const cached = imageCache.get(item.id);

      if (cached) {
        renderDecodedImage(imgContainer, item, cached);
      } else {
        const skeleton = h(
          "div",
          { class: "cb-image-skeleton" },
          svg(ICONS.eye, 24),
          h("span", { text: "Loading image…" }),
        );
        imgContainer.append(skeleton);

        void Bridge.clipboardGetImageData(item.id)
          .then((res) => {
            if (res) {
              imageCache.set(item.id, res);
              imgContainer.innerHTML = "";
              renderDecodedImage(imgContainer, item, res);
              renderPreviewFooter(item, res);
            } else {
              renderImageError(imgContainer, item);
            }
          })
          .catch(() => {
            renderImageError(imgContainer, item);
          });
      }
      pb.append(imgContainer);
    } else if (item.kind === "link") {
      // Dedicated Link Preview: centered balanced macOS card
      const linkWrap = h("div", { class: "cb-link-preview-wrap" });
      const linkCard = h("div", { class: "cb-link-card" });

      const domainHeader = h(
        "div",
        { class: "cb-link-domain-badge" },
        svg(ICONS.arrowUpRight, 13),
        h("span", { text: item.preview || "Website Link" }),
      );

      const urlContainer = h("div", { class: "cb-link-url-box" }, item.content);

      const openBtn = h(
        "button",
        {
          class: "cb-link-open-btn",
          onclick: () => actions.openUrl(item.content),
        },
        svg(ICONS.arrowUpRight, 12),
        h("span", { text: t("Open in Browser") }),
      );

      linkCard.append(domainHeader, urlContainer, openBtn);
      linkWrap.append(linkCard);
      pb.append(linkWrap);
    } else {
      // Dedicated Text Preview
      const isCode = isCodeSnippet(item.content);
      if (isCode) {
        const codeBlock = h(
          "div",
          { class: "cb-preview-code-block" },
          h("pre", { class: "cb-code-content" }, item.content),
        );
        pb.append(codeBlock);
      } else {
        const proseBlock = h("div", { class: "cb-preview-prose" }, item.content);
        pb.append(proseBlock);
      }
    }

    // ── Preview Footer: Minimal Action Bar ────────────────────────────────────
    const pf = h("div", { class: "cb-preview-footer" });
    previewPanel.append(ph, pb, pf);
    renderPreviewFooter(item, imageCache.get(item.id));
  }

  function renderPreviewFooter(item: ClipboardItem, cachedImg?: ImageDataResult) {
    const pf = previewPanel.querySelector(".cb-preview-footer");
    if (!pf) return;
    pf.innerHTML = "";

    // Clear single metadata line on left
    let metaStr = "";
    if (item.kind === "image") {
      const w = cachedImg?.width ?? item.imageWidth ?? 0;
      const h_dim = cachedImg?.height ?? item.imageHeight ?? 0;
      const sizeStr = cachedImg?.sizeBytes ? ` · ${formatBytes(cachedImg.sizeBytes)}` : "";
      const formatStr = cachedImg?.format ? ` · ${cachedImg.format}` : "";
      metaStr = `${w} × ${h_dim} px${sizeStr}${formatStr}`;
    } else if (item.kind === "link") {
      metaStr = item.preview || "link";
    } else {
      const parts: string[] = [];
      if (item.wordCount != null) parts.push(`${item.wordCount} words`);
      if (item.charCount != null) parts.push(`${item.charCount} chars`);
      metaStr = parts.join(" · ");
    }
    const metaEl = h("div", { class: "cb-preview-meta" }, metaStr);

    // Primary Copy Action with border-2 token
    const copyLabel = state.copyFeedback ?? t("Copy");
    const copyBtn = h(
      "button",
      {
        class: `cb-copy-btn border-2 ${state.copyFeedback ? "success" : ""}`,
        onclick: async () => {
          const result = await Bridge.clipboardCopyItem(item.id);
          if (result?.ok) {
            actions.blip();
            state.copyFeedback = "Copied ✓";
            renderPreviewFooter(item, imageCache.get(item.id));
            setTimeout(() => {
              state.copyFeedback = null;
              renderPreviewFooter(item, imageCache.get(item.id));
            }, 1500);
          }
        },
      },
      svg(ICONS.copy, 13),
      h("span", { text: copyLabel }),
    );

    // More Context Menu Action (anchored directly to button)
    const moreBtn = h(
      "button",
      {
        class: "cb-icon-btn",
        title: "More actions",
        onclick: (e: Event) => {
          e.stopPropagation();
          showItemContextMenu(item, moreBtn);
        },
      },
      svg(ICONS.ellipsis, 14),
    );

    pf.append(metaEl, copyBtn, moreBtn);
  }

  function renderDecodedImage(container: HTMLElement, item: ClipboardItem, data: ImageDataResult) {
    const frame = h("div", { class: "cb-image-frame" });
    const img = h("img", {
      class: "cb-preview-image",
      src: data.dataUrl,
      alt: item.preview || "Clipboard image",
    }) as HTMLImageElement;

    frame.append(img);
    container.append(frame);
  }

  function renderImageError(container: HTMLElement, item: ClipboardItem) {
    container.innerHTML = "";
    const errorCard = h(
      "div",
      { class: "cb-image-error-card" },
      svg(ICONS.bang, 20),
      h("span", { text: t("Image could not be loaded") }),
      h(
        "button",
        {
          class: "cb-retry-btn",
          onclick: () => {
            imageCache.delete(item.id);
            renderPreview();
          },
        },
        svg(ICONS.arrowClockwise, 12),
        h("span", { text: t("Retry") }),
      ),
    );
    container.append(errorCard);
  }

  function renderAll() {
    if (state.loading) {
      if (currentViewMode !== "loading") {
        currentViewMode = "loading";
        root.innerHTML = "";
        root.append(buildLoadingState());
      }
      return;
    }

    if (!state.monitoring && state.items.length === 0) {
      if (currentViewMode !== "paused") {
        currentViewMode = "paused";
        root.innerHTML = "";
        root.append(buildPausedState());
      }
      return;
    }

    if (state.items.length === 0) {
      if (currentViewMode !== "empty") {
        currentViewMode = "empty";
        root.innerHTML = "";
        root.append(buildEmptyState());
      }
      return;
    }

    // Populated state: mount layout persistently without recreating DOM tree
    if (currentViewMode !== "populated") {
      currentViewMode = "populated";
      root.innerHTML = "";
      root.append(populatedLayout);
      requestAnimationFrame(() => updateActiveSegment(true));
    }

    renderTitle();
    updateSegmentCounts();
    updateActiveSegment(false);
    renderHistory();
    renderPreview();
  }

  async function loadHistory() {
    try {
      const [history, monitoring] = await Promise.all([
        Bridge.clipboardGetHistory(),
        Bridge.clipboardIsMonitoring().catch(() => true),
      ]);
      state.items = history?.items ?? [];
      state.monitoring = monitoring ?? true;
      if (state.selectedId && !state.items.find((i) => i.id === state.selectedId)) {
        state.selectedId = state.items[0]?.id ?? null;
      }
      if (!state.selectedId && state.items.length > 0) {
        state.selectedId = state.items[0].id;
      }
    } catch {
      state.items = [];
    } finally {
      state.loading = false;
    }
  }

  // ── Initial load & live updates ────────────────────────────────────────────
  void loadHistory().then(() => renderAll());

  // Listen for real-time clipboard changes from Windows backend
  void onEvent<null>("clipboard-changed", async () => {
    await loadHistory();
    renderAll();
  });

  return {
    el: root,
    sync() {
      void loadHistory().then(() => renderAll());
    },
  };
}

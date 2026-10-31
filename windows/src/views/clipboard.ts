// The notch's Clipboard tab: the last things copied, as a row of cards to copy
// or paste again (src-tauri/src/clipboard.rs keeps them, in memory only).
// Mochi sits on the left like on the other cards; a toolbar with the filters
// above a strip that scrolls sideways, with the wheel too.

import { h, clear, svg } from "./dom";
import { ICONS } from "./icons";
import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import { ago, fileName, linkHost, look, ordered, type ClipFilter, type ClipItem, type ClipLook } from "../core/clipboard";
import { language, t, tl } from "../i18n/i18n";
import type { ViewHost } from "./views";

const FILTERS: [ClipFilter, () => string][] = [
  ["all", () => t("All")],
  ["text", () => t("Text")],
  ["links", () => t("Links")],
  ["images", () => t("Images")],
  ["files", () => t("Files")],
];

const LOOK_ICON: Record<ClipLook, string> = {
  text: ICONS.textLines,
  code: ICONS.code,
  link: ICONS.link,
  color: ICONS.palette,
  image: ICONS.image,
  files: ICONS.file,
};

function iconButton(path: string, title: string, onClick: () => void, cls = ""): HTMLButtonElement {
  return h("button", {
    class: `clip-act ${cls}`.trim(),
    title,
    "aria-label": title,
    onclick: (e: Event) => {
      e.stopPropagation();
      onClick();
    },
  }, svg(path, 13, { stroke: 1.9 })) as HTMLButtonElement;
}

export function buildClipboard(): ViewHost {
  let filter: ClipFilter = "all";
  /** The cards on screen, by item id, and what they were built from. */
  let shownKey = "";
  const times = new Map<number, HTMLElement>();
  /** Image cards' pictures, asked for once. */
  const images = new Map<number, string>();

  const count = h("span", { class: "clip-count" });
  const chips = FILTERS.map(([f, label]) => {
    const b = h("button", { class: "clip-chip", text: label() }) as HTMLButtonElement;
    b.addEventListener("click", () => {
      filter = f;
      shownKey = "";
      render();
    });
    return { f, b, label };
  });
  const clearBtn = h("button", { class: "clip-clear", text: t("Clear") }) as HTMLButtonElement;
  clearBtn.addEventListener("click", () => void Bridge.clipboardClear());

  const strip = h("div", { class: "clip-strip" });
  // A plain wheel scrolls the row sideways.
  strip.addEventListener("wheel", (e: WheelEvent) => {
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
      strip.scrollLeft += e.deltaY;
      e.preventDefault();
    }
  }, { passive: false });
  const empty = h("div", { class: "clip-empty" },
    svg(ICONS.clipboard, 22, { stroke: 1.6 }),
    h("div", { text: tl("Copy something: it shows up here.") }),
  );

  const root = h("div", { class: "clip-root" },
    h("div", { class: "clip-bar" },
      h("span", { class: "clip-title" }, svg(ICONS.clipboard, 13, { stroke: 1.9 }), h("span", { text: tl("Clipboard") })),
      count,
      h("div", { class: "clip-chips" }, ...chips.map((c) => c.b)),
      h("div", { class: "grow" }),
      clearBtn,
    ),
    strip,
    empty,
  );
  const el = h("div", { class: "view" }, h("div", { class: "card clip-cardbox" }, root));

  function flash(card: HTMLElement) {
    card.classList.remove("done");
    void card.offsetWidth;
    card.classList.add("done");
  }

  function body(item: ClipItem, l: ClipLook): HTMLElement {
    switch (l) {
      case "link":
        return h("div", { class: "clip-body" },
          h("div", { class: "clip-host", text: linkHost(item.text) }),
          h("div", { class: "clip-url", text: item.text.trim() }));
      case "color": {
        const code = item.text.trim();
        const swatch = h("div", { class: "clip-swatch" });
        swatch.style.background = code;
        return h("div", { class: "clip-body clip-colorbody" }, swatch, h("div", { class: "clip-hex", text: code }));
      }
      case "code":
        return h("div", { class: "clip-body" }, h("pre", { class: "clip-code", text: item.text }));
      case "image": {
        const img = h("img", { class: "clip-img", alt: "" }) as HTMLImageElement;
        const known = images.get(item.id);
        if (known) img.src = known;
        else
          void Bridge.clipboardImage(item.id).then((url) => {
            if (!url) return;
            images.set(item.id, url);
            img.src = url;
          });
        return h("div", { class: "clip-body clip-imgbody" }, img);
      }
      case "files": {
        const first = fileName(item.files[0] ?? item.text);
        const more = item.files.length > 1 ? t("{count} files", { count: item.files.length }) : "";
        return h("div", { class: "clip-body clip-filesbody" },
          svg(ICONS.file, 26, { stroke: 1.5 }),
          h("div", { class: "clip-fname", text: first }),
          h("div", { class: "clip-fmore", text: more }));
      }
      default:
        return h("div", { class: "clip-body" }, h("div", { class: "clip-text", text: item.text }));
    }
  }

  function cardFor(item: ClipItem): HTMLElement {
    const l = look(item);
    const time = h("span", { class: "clip-time" });
    times.set(item.id, time);
    const pin = iconButton(ICONS.pin, item.pinned ? t("Unpin") : t("Pin"),
      () => void Bridge.clipboardPin(item.id, !item.pinned), item.pinned ? "on" : "");
    const card = h("div", { class: `clip-card look-${l}${item.pinned ? " pinned" : ""}`, title: t("Copy") },
      h("div", { class: "clip-top" },
        h("span", { class: "clip-kind" }, svg(LOOK_ICON[l], 11, { stroke: 2 })),
        h("span", { class: "clip-app", text: item.app ?? "" }),
        time,
        item.pinned ? h("span", { class: "clip-pinmark" }, svg(ICONS.pin, 10, { stroke: 2 })) : h("span", {}),
      ),
      body(item, l),
      h("div", { class: "clip-acts" },
        iconButton(ICONS.pasteIn, t("Paste"), () => void Bridge.clipboardPaste(item.id), "primary"),
        pin,
        iconButton(ICONS.trash, t("Delete"), () => {
          images.delete(item.id);
          void Bridge.clipboardDelete(item.id);
        }),
      ),
      h("div", { class: "clip-done" }, svg(ICONS.check, 16, { stroke: 2.4 }), h("span", { text: t("Copied") })),
    );
    card.addEventListener("click", () => {
      void Bridge.clipboardCopy(item.id).then((ok) => {
        if (ok) flash(card);
      });
    });
    return card;
  }

  function render() {
    const all = State.clipboard;
    const items = ordered(all, filter);
    const key = `${filter}|${language()}|${items.map((i) => `${i.id}:${i.pinned ? 1 : 0}:${i.at}`).join(",")}`;
    if (key !== shownKey) {
      shownKey = key;
      times.clear();
      clear(strip);
      for (const item of items) strip.append(cardFor(item));
      // Images of items that are gone are let go.
      for (const id of [...images.keys()]) if (!all.some((i) => i.id === id)) images.delete(id);
      for (const c of chips) {
        c.b.classList.toggle("on", c.f === filter);
        if (c.b.textContent !== c.label()) c.b.textContent = c.label();
      }
    }
    const n = String(all.length);
    if (count.textContent !== n) count.textContent = n;
    const isEmpty = items.length === 0;
    empty.classList.toggle("on", isEmpty);
    strip.classList.toggle("off", isEmpty);
    clearBtn.classList.toggle("off", !all.some((i) => !i.pinned));
    // "2 min. ago" moves on without rebuilding anything.
    const now = Date.now();
    for (const item of items) {
      const el = times.get(item.id);
      const text = ago(item.at, now, language());
      if (el && el.textContent !== text) el.textContent = text;
    }
  }

  return {
    el,
    sync() {
      if (State.view === "clipboard") render();
    },
  };
}

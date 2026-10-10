// The colour dot at the start of a pill's row, and the palette it opens — the
// Mac's dot in Settings → Active pills does the same. The dot looks exactly as
// it always did; what is new is that it can be clicked.

import { PILL_PALETTE, pillColor, withPillColor } from "../core/pill-colors";
import { h } from "../views/dom";
import { t } from "../i18n/i18n";

/** The palette on screen, if any: there is never more than one. */
let closeOpen: (() => void) | null = null;

/**
 * `colors` reads the preference as it is now, `pick` is given the next one.
 * `size` is the dot's own inline style, as each row had it.
 */
export function colorDot(
  def: { id: string; name: string; color: string },
  size: string,
  colors: () => unknown,
  pick: (next: Record<string, string>) => void,
): HTMLElement {
  const current = () => pillColor(def.id, def.color, colors());
  const dot = h("i", {
    class: "dot color-dot",
    role: "button",
    tabindex: "0",
    style: `background:${current()};${size}`,
    title: t("Color"),
    "aria-label": `${def.name} · ${t("Color")}`,
    "aria-haspopup": "true",
  });

  const open = () => {
    closeOpen?.();
    const palette = h("div", { class: "palette", role: "group", "aria-label": t("Color") });

    const close = () => {
      palette.remove();
      document.removeEventListener("mousedown", outside, true);
      document.removeEventListener("keydown", onKey, true);
      window.removeEventListener("resize", close);
      closeOpen = null;
    };
    const outside = (e: Event) => {
      const at = e.target as Node;
      if (!palette.contains(at) && at !== dot) close();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      close();
      dot.focus();
    };
    const choose = (hex: string | null) => {
      pick(withPillColor(colors(), def.id, hex, def.color));
      dot.style.background = current();
      close();
      dot.focus();
    };

    const now = current();
    for (const hex of PILL_PALETTE) {
      const swatch = h("button", {
        class: hex === now ? "swatch on" : "swatch",
        style: `background:${hex}`,
        title: hex,
        "aria-label": hex,
        "aria-pressed": hex === now,
      });
      swatch.addEventListener("click", () => choose(hex));
      palette.append(swatch);
    }
    // Back to the catalog's colour: only offered once it has been changed.
    if (now !== pillColor(def.id, def.color, null)) {
      const reset = h("button", { class: "reset", text: t("Default") });
      reset.addEventListener("click", () => choose(null));
      palette.append(reset);
    }

    document.body.append(palette);
    // Under the dot, kept inside the window whichever way the text runs.
    const at = dot.getBoundingClientRect();
    const left = Math.max(8, Math.min(at.left - 10, window.innerWidth - palette.offsetWidth - 8));
    palette.style.left = `${left}px`;
    palette.style.top = `${at.bottom + 8}px`;

    document.addEventListener("mousedown", outside, true);
    document.addEventListener("keydown", onKey, true);
    window.addEventListener("resize", close);
    closeOpen = close;
    (palette.querySelector<HTMLElement>(".swatch.on") ?? palette.querySelector<HTMLElement>(".swatch"))?.focus();
  };

  dot.addEventListener("click", () => (closeOpen ? closeOpen() : open()));
  dot.addEventListener("keydown", (e) => {
    const key = (e as KeyboardEvent).key;
    if (key !== "Enter" && key !== " ") return;
    e.preventDefault();
    open();
  });
  return dot;
}

// Liquid Glass dropdown menu — matches the macOS System Settings dark aesthetic.
// Works with the existing h() DOM helper; no React, no Tailwind required.
//
// Usage:
//   const menu = dropdown([
//     { label: "General",    icon: "gear",    onClick: () => show("general") },
//     { label: "Shortcuts",  icon: "sliders", onClick: () => show("shortcuts") },
//     { type: "separator" },
//     { label: "Quit",       icon: "x",       onClick: () => quit(), danger: true },
//   ]);
//   document.body.append(menu.trigger("⚙ Settings"));
//
// Or attach the panel directly to a custom trigger:
//   button.addEventListener("click", (e) => menu.open(e.currentTarget as HTMLElement));

import "./dropdown.css";
import { h } from "./dom";
import { animate, stagger, MACOS_JELLY } from "../hub/motion";
import { Sound } from "../core/sound";

/** A regular item in the menu. */
export interface DropdownItem {
  type?: "item";
  label: string;
  /** An icon key from HUB_ICONS — optional. */
  icon?: string;
  /** Shortcut hint shown on the right (e.g. "⌘K"). */
  shortcut?: string;
  /** Whether this item is destructive (shown in red). */
  danger?: boolean;
  /** Whether the item appears disabled. */
  disabled?: boolean;
  /** Whether the item shows a checkmark. */
  checked?: boolean;
  onClick(): void;
}

/** A visual separator between groups. */
export interface DropdownSeparator {
  type: "separator";
}

/** A section label (non-interactive heading). */
export interface DropdownLabel {
  type: "label";
  label: string;
}

export type DropdownEntry = DropdownItem | DropdownSeparator | DropdownLabel;

// SVG paths for optional inline icons (subset of HUB_ICONS).
const INLINE_ICONS: Record<string, string> = {
  gear:     "M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 2.8v2.4M12 18.8v2.4M2.8 12h2.4M18.8 12h2.4M5.5 5.5l1.7 1.7M16.8 16.8l1.7 1.7M5.5 18.5l1.7-1.7M16.8 7.2l1.7-1.7",
  sliders:  "M4 7h9M17 7h3M4 17h3M11 17h9M15 5v4M9 15v4",
  bolt:     "M13 3 5 13h6l-1 8 8-10h-6l1-8z",
  trash:    "M5 7h14M10 4h4M7 7l1 13h8l1-13M10 11v6M14 11v6",
  pin:      "M16 12V4h1V2H7v2h1v8l-2 2v2h5.2v6h1.6v-6H18v-2l-2-2z",
  x:        "M6.5 6.5l11 11M17.5 6.5l-11 11",
  check:    "M5 12.5 9.5 17 19 7.5",
  copy:     "M8.5 8.5h11v11.5h-11zM5 15.5V4h11",
  pencil:   "M4.5 19.5l4-1 10.5-10.5-3-3L5.5 15.5l-1 4z",
  download: "M12 4v11M7 10l5 5 5-5M5 20h14",
  lock:     "M6.5 11h11v9h-11zM8.5 11V8a3.5 3.5 0 0 1 7 0v3",
  dots:     "M6 12h.01M12 12h.01M18 12h.01",
  chart:    "M5 20v-7M10 20V6M15 20v-9M20 20V9",
  puzzle:   "M9 4h4v2a1.8 1.8 0 1 0 3.6 0V4H20v5.5h-2a1.8 1.8 0 1 0 0 3.6h2V20h-5.5v-2a1.8 1.8 0 1 0-3.6 0v2H4v-6.4h2a1.8 1.8 0 1 0 0-3.6H4V4h5z",
};

// SVG icon builder.
function iconSvg(name: string, size = 14): SVGSVGElement {
  const path = INLINE_ICONS[name];
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", String(size));
  svg.setAttribute("height", String(size));
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.75");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  if (path) {
    const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
    p.setAttribute("d", path);
    svg.append(p);
  }
  return svg;
}

// Checkmark SVG.
function checkSvg(): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", "13");
  svg.setAttribute("height", "13");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "2.2");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
  p.setAttribute("d", "M5 12.5 9.5 17 19 7.5");
  svg.append(p);
  return svg;
}

// Shared state: only one panel open at a time.
let activePanel: HTMLElement | null = null;
let activeTrigger: HTMLElement | null = null;
let activeCleanup: (() => void) | null = null;

function closeActive() {
  if (activeCleanup) {
    const cleanup = activeCleanup;
    activeCleanup = null;
    cleanup();
  }
  if (activeTrigger) {
    activeTrigger.classList.remove("open");
    activeTrigger = null;
  }
  if (activePanel) {
    const panel = activePanel;
    activePanel = null;
    animate(
      panel,
      { opacity: 0, scale: 0.94, y: -4 },
      { duration: 0.14, ease: [0.32, 0, 0.67, 0] }
    ).then(() => {
      panel.remove();
    });
  }
}

export interface PlacementOptions {
  padding?: number;
  offset?: number;
  maxHeightCap?: number;
}

export interface PlacementResult {
  left: number;
  top: number;
  maxHeight: number;
  isFlipped: boolean;
  isRightAligned: boolean;
  transformOrigin: string;
}

/**
 * Computes collision-free, deterministic placement for dropdown menus.
 *
 * Rules:
 * 1. Checks available space below and above the trigger anchor within viewport bounds.
 * 2. Prefers downward placement if menu fits completely below.
 * 3. Flips upward only if it fits cleanly above AND above has more space.
 * 4. When the menu cannot fit fully in either direction without scroll, chooses the direction
 *    with the LARGER available space and constrains maxHeight (enabling sleek scrolling).
 * 5. Strictly clamps top and left within [padding, viewport - size - padding] so menus
 *    NEVER escape into negative coordinates or clip outside window boundaries.
 */
export function calculateDropdownPlacement(
  anchorRect: { top: number; bottom: number; left: number; right: number; width?: number; height?: number },
  panelWidth: number,
  panelHeight: number,
  viewportWidth: number,
  viewportHeight: number,
  options: PlacementOptions = {},
): PlacementResult {
  const padding = options.padding ?? 8;
  const offset = options.offset ?? 6;
  const maxHeightCap = options.maxHeightCap ?? 380;

  // Space available above and below anchor within viewport padding
  const spaceBelow = Math.max(0, viewportHeight - anchorRect.bottom - offset - padding);
  const spaceAbove = Math.max(0, anchorRect.top - offset - padding);

  let isFlipped = false;
  let availableHeight = spaceBelow;

  // Directional placement logic
  if (panelHeight <= spaceBelow) {
    // Fits cleanly below (standard reading flow)
    isFlipped = false;
    availableHeight = spaceBelow;
  } else if (panelHeight <= spaceAbove && spaceAbove > spaceBelow) {
    // Doesn't fit below, but fits cleanly above with more space
    isFlipped = true;
    availableHeight = spaceAbove;
  } else {
    // Neither fits completely without scroll: pick the side with LARGER available space!
    if (spaceAbove > spaceBelow) {
      isFlipped = true;
      availableHeight = spaceAbove;
    } else {
      isFlipped = false;
      availableHeight = spaceBelow;
    }
  }

  // Constrain height to available space and cap
  const maxHeight = Math.min(panelHeight, availableHeight, maxHeightCap);
  // Guarantee a reasonable minimal height so menus in tight spots remain readable
  const effectiveHeight = Math.max(Math.min(60, availableHeight), maxHeight);

  // Compute top coordinate
  let top = isFlipped
    ? anchorRect.top - offset - effectiveHeight
    : anchorRect.bottom + offset;

  // Strict viewport boundary protection: NEVER allow negative top or bottom overflow
  top = Math.max(padding, Math.min(top, viewportHeight - effectiveHeight - padding));

  // Compute horizontal coordinate
  let left = anchorRect.left;
  let isRightAligned = false;

  // If overflowing right edge, align right edge of panel to right edge of anchor
  if (left + panelWidth > viewportWidth - padding) {
    left = anchorRect.right - panelWidth;
    isRightAligned = true;
  }

  // Strict viewport boundary protection: NEVER allow left or right overflow
  left = Math.max(padding, Math.min(left, viewportWidth - panelWidth - padding));

  // Natural bloom transform origin
  const vOrigin = isFlipped ? "bottom" : "top";
  const hOrigin = isRightAligned ? "right" : "left";
  const transformOrigin = `${vOrigin} ${hOrigin}`;

  return {
    left: Math.round(left),
    top: Math.round(top),
    maxHeight: Math.round(effectiveHeight),
    isFlipped,
    isRightAligned,
    transformOrigin,
  };
}

export interface DropdownOptions {
  className?: string;
  minWidth?: number;
  maxWidth?: number;
  matchAnchorWidth?: boolean;
}

/** Creates and returns a dropdown menu controller. */
export function dropdown(items: DropdownEntry[], options: DropdownOptions = {}) {
  const hasAnyCheck = items.some(
    (entry) => entry.type !== "separator" && entry.type !== "label" && (entry as DropdownItem).checked !== undefined,
  );

  function buildPanel(): HTMLElement {
    const classes = ["dd-panel", hasAnyCheck ? "has-checks" : "no-checks", options.className].filter(Boolean).join(" ");
    const panel = h("div", { class: classes, role: "menu" });

    for (const entry of items) {
      if (entry.type === "separator") {
        panel.append(h("div", { class: "dd-separator", role: "separator" }));
        continue;
      }
      if (entry.type === "label") {
        panel.append(h("div", { class: "dd-label", text: entry.label }));
        continue;
      }

      // Regular item.
      const item = entry as DropdownItem;
      const btn = h("button", {
        class: ["dd-item", item.danger ? "dd-danger" : "", item.disabled ? "dd-disabled" : ""].filter(Boolean).join(" "),
        role: "menuitem",
        type: "button",
        ...(item.disabled ? { "aria-disabled": "true" } : {}),
        onclick: () => {
          if (!item.disabled) {
            Sound.resume();
            Sound.play("tick");
            closeActive();
            item.onClick();
          }
        },
      });

      // Check indicator column (only present when the menu has checkable items).
      if (hasAnyCheck) {
        const checkCol = h("span", { class: "dd-check-col", "aria-hidden": "true" });
        if (item.checked) checkCol.append(checkSvg());
        btn.append(checkCol);
      }

      // Optional icon.
      if (item.icon) {
        const iconEl = h("span", { class: "dd-icon-col", "aria-hidden": "true" });
        iconEl.append(iconSvg(item.icon));
        btn.append(iconEl);
      }

      // Label.
      btn.append(h("span", { class: "dd-item-label", text: item.label }));

      // Optional shortcut hint.
      if (item.shortcut) {
        btn.append(h("kbd", { class: "dd-shortcut", text: item.shortcut }));
      }

      panel.append(btn);
    }

    return panel;
  }

  /** Opens the menu anchored to `anchor`. */
  function open(anchor: HTMLElement) {
    if (activePanel) {
      const isSame = activeTrigger === anchor;
      closeActive();
      if (isSame) return;
    }

    activeTrigger = anchor;
    anchor.classList.add("open");
    Sound.resume();
    Sound.play("open");

    const panel = buildPanel();
    document.body.append(panel);
    activePanel = panel;

    const updatePosition = (): PlacementResult | null => {
      if (!activePanel || !anchor.isConnected) {
        closeActive();
        return null;
      }
      const rect = anchor.getBoundingClientRect();
      // If anchor scrolled off-screen completely, close cleanly
      if (
        rect.bottom < 0 ||
        rect.top > window.innerHeight ||
        rect.right < 0 ||
        rect.left > window.innerWidth
      ) {
        closeActive();
        return null;
      }

      if (options.minWidth != null) {
        panel.style.minWidth = `${options.minWidth}px`;
      } else if (options.matchAnchorWidth === false || !anchor.classList.contains("dd-trigger")) {
        panel.style.minWidth = "140px";
      } else {
        panel.style.minWidth = `${Math.max(125, Math.round(rect.width))}px`;
      }

      if (options.maxWidth != null) {
        panel.style.maxWidth = `${options.maxWidth}px`;
      }

      const actualW = panel.offsetWidth || options.minWidth || 140;
      const actualH = panel.scrollHeight || panel.offsetHeight || items.length * 36;

      const placement = calculateDropdownPlacement(
        rect,
        actualW,
        actualH,
        window.innerWidth,
        window.innerHeight,
        { padding: 8, offset: 6 }
      );

      panel.style.left = `${placement.left}px`;
      panel.style.top = `${placement.top}px`;
      panel.style.maxHeight = `${placement.maxHeight}px`;
      panel.style.overflowY = actualH > placement.maxHeight ? "auto" : "hidden";
      panel.style.transformOrigin = placement.transformOrigin;

      return placement;
    };

    const initialPlacement = updatePosition();
    if (!initialPlacement) return;

    panel.style.willChange = "transform, opacity";

    // macOS Liquid Glass jelly bloom entrance
    animate(
      panel,
      {
        opacity: [0, 1],
        scale: [0.90, 1.035, 0.992, 1],
        y: [initialPlacement.isFlipped ? 8 : -8, initialPlacement.isFlipped ? -2 : 2, 0],
      },
      MACOS_JELLY.dropdownOpen
    );

    // Stagger items micro-ripple
    const itemElements = Array.from(panel.querySelectorAll<HTMLElement>(".dd-item"));
    if (itemElements.length > 0) {
      for (const el of itemElements) el.style.willChange = "transform, opacity";
      animate(
        itemElements,
        {
          opacity: [0, 1],
          x: [-6, 1, 0],
        },
        { delay: stagger(0.016), ...MACOS_JELLY.dropdownItem }
      );
    }

    // Close on outside click / Escape / Keyboard navigation
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") { closeActive(); return; }
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        const btns = Array.from(panel.querySelectorAll<HTMLElement>(".dd-item:not(.dd-disabled)"));
        if (btns.length === 0) return;
        const idx = btns.indexOf(document.activeElement as HTMLElement);
        const next = e.key === "ArrowDown" ? (idx + 1) % btns.length : (idx - 1 + btns.length) % btns.length;
        btns[next]?.focus();
        return;
      }
      if (e.key === "Enter" || e.key === " ") {
        const focused = document.activeElement as HTMLElement | null;
        if (focused && panel.contains(focused) && focused.classList.contains("dd-item")) {
          e.preventDefault();
          focused.click();
          return;
        }
      }
      // macOS typeahead search: jump to option starting with typed character
      if (e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
        const char = e.key.toLowerCase();
        const btns = Array.from(panel.querySelectorAll<HTMLElement>(".dd-item:not(.dd-disabled)"));
        const match = btns.find((btn) => btn.textContent?.trim().toLowerCase().startsWith(char));
        if (match) {
          match.focus();
        }
      }
    };
    const onDown = (e: MouseEvent) => {
      if (!panel.contains(e.target as Node) && !anchor.contains(e.target as Node)) {
        closeActive();
      }
    };

    const onReposition = () => {
      if (activePanel) updatePosition();
    };

    const cleanup = () => {
      document.removeEventListener("keydown", onKey, true);
      document.removeEventListener("mousedown", onDown, true);
      window.removeEventListener("resize", onReposition);
      window.removeEventListener("scroll", onReposition, true);
    };

    activeCleanup = cleanup;
    document.addEventListener("keydown", onKey, true);
    document.addEventListener("mousedown", onDown, true);
    window.addEventListener("resize", onReposition, { passive: true });
    window.addEventListener("scroll", onReposition, { passive: true, capture: true });

    // Focus first item.
    requestAnimationFrame(() => {
      const first = panel.querySelector<HTMLElement>(".dd-item:not(.dd-disabled)");
      first?.focus();
    });
  }

  /** Builds a pre-wired trigger button. */
  function trigger(label: string, iconName?: string): HTMLButtonElement {
    const btn = h("button", { class: "dd-trigger" }) as HTMLButtonElement;
    if (iconName) btn.append(iconSvg(iconName, 16));
    btn.append(h("span", { text: label }));
    // Chevron down.
    const chevron = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    chevron.setAttribute("viewBox", "0 0 24 24");
    chevron.setAttribute("width", "12");
    chevron.setAttribute("height", "12");
    chevron.setAttribute("fill", "none");
    chevron.setAttribute("stroke", "currentColor");
    chevron.setAttribute("stroke-width", "2.5");
    chevron.setAttribute("stroke-linecap", "round");
    const cp = document.createElementNS("http://www.w3.org/2000/svg", "path");
    cp.setAttribute("d", "M6 9l6 6 6-6");
    chevron.append(cp);
    btn.append(chevron);
    btn.addEventListener("click", () => open(btn));
    return btn;
  }

  return { open, trigger, close: closeActive };
}

export interface DropdownSelect<T extends string = string> extends HTMLButtonElement {
  value: T;
  disabled: boolean;
  setOptions(options: [T, string][]): void;
}

/**
 * Creates a drop-in replacement for <select> elements using the macOS Liquid Glass dropdown menu.
 */
export function dropdownSelect<T extends string = string>(
  options: [T, string][],
  value: T,
  onChange?: (v: T) => void,
  attrs: { class?: string; ariaLabel?: string; style?: string } = {},
): DropdownSelect<T> {
  let currentOptions = [...options];
  let currentValue = value;
  let isDisabled = false;

  const btn = h("button", {
    class: `dd-trigger ${attrs.class ?? ""}`.trim(),
    style: attrs.style ?? "",
    type: "button",
    ...(attrs.ariaLabel ? { "aria-label": attrs.ariaLabel } : {}),
  }) as unknown as DropdownSelect<T>;

  const labelSpan = h("span", {
    class: "dd-trigger-text",
    text: currentOptions.find(([id]) => id === currentValue)?.[1] ?? String(currentValue),
  });
  btn.append(labelSpan);

  // Chevron down
  const chevron = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  chevron.setAttribute("viewBox", "0 0 24 24");
  chevron.setAttribute("width", "12");
  chevron.setAttribute("height", "12");
  chevron.setAttribute("fill", "none");
  chevron.setAttribute("stroke", "currentColor");
  chevron.setAttribute("stroke-width", "2.5");
  chevron.setAttribute("stroke-linecap", "round");
  const cp = document.createElementNS("http://www.w3.org/2000/svg", "path");
  cp.setAttribute("d", "M6 9l6 6 6-6");
  chevron.append(cp);
  btn.append(chevron);

  // Hidden native <select> so tests & form interactions can query options and fire change
  const hiddenSelect = h("select", {
    style: "display:none;position:absolute;opacity:0;pointer-events:none",
    tabIndex: -1,
    "aria-hidden": "true",
  }) as HTMLSelectElement;

  const updateHiddenSelect = () => {
    if (typeof hiddenSelect.replaceChildren === "function") {
      hiddenSelect.replaceChildren(
        ...currentOptions.map(([id, label]) => {
          const opt = h("option", { value: id, text: label }) as HTMLOptionElement;
          if (id === currentValue) opt.selected = true;
          return opt;
        }),
      );
    } else {
      while (hiddenSelect.firstChild) hiddenSelect.removeChild(hiddenSelect.firstChild);
      for (const [id, label] of currentOptions) {
        const opt = h("option", { value: id, text: label }) as HTMLOptionElement;
        if (id === currentValue) opt.selected = true;
        hiddenSelect.append(opt);
      }
    }
    hiddenSelect.value = currentValue;
  };
  updateHiddenSelect();

  hiddenSelect.addEventListener("change", () => {
    if (hiddenSelect.disabled || isDisabled) return;
    const next = hiddenSelect.value as T;
    if (next !== currentValue) {
      currentValue = next;
      const found = currentOptions.find(([id]) => id === next);
      labelSpan.textContent = found ? found[1] : String(next);
      onChange?.(next);
      if (typeof btn.dispatchEvent === "function") {
        btn.dispatchEvent(new Event("change", { bubbles: true }));
      } else if (typeof (btn as unknown as { fire?: (t: string) => void }).fire === "function") {
        (btn as unknown as { fire: (t: string) => void }).fire("change");
      }
    }
  });
  btn.append(hiddenSelect);

  btn.addEventListener("click", () => {
    if (isDisabled) return;
    const menu = dropdown(
      currentOptions.map(([id, label]) => ({
        label,
        checked: id === currentValue,
        onClick: () => {
          if (currentValue !== id) {
            currentValue = id;
            hiddenSelect.value = id;
            labelSpan.textContent = label;
            onChange?.(id);
            if (typeof btn.dispatchEvent === "function") {
              btn.dispatchEvent(new Event("change", { bubbles: true }));
            } else if (typeof (btn as unknown as { fire?: (t: string) => void }).fire === "function") {
              (btn as unknown as { fire: (t: string) => void }).fire("change");
            }
          }
        },
      })),
    );
    menu.open(btn as unknown as HTMLElement);
  });

  Object.defineProperty(btn, "value", {
    get() {
      return currentValue;
    },
    set(v: T) {
      currentValue = v;
      hiddenSelect.value = v;
      const found = currentOptions.find(([id]) => id === v);
      labelSpan.textContent = found ? found[1] : String(v);
    },
    configurable: true,
  });

  Object.defineProperty(btn, "disabled", {
    get() {
      return isDisabled;
    },
    set(d: boolean) {
      isDisabled = d;
      hiddenSelect.disabled = d;
      btn.classList.toggle("dd-disabled", d);
      if (d) btn.setAttribute("disabled", "true");
      else btn.removeAttribute("disabled");
    },
    configurable: true,
  });

  btn.setOptions = (nextOptions: [T, string][]) => {
    currentOptions = [...nextOptions];
    updateHiddenSelect();
    const found = currentOptions.find(([id]) => id === currentValue);
    if (found) {
      labelSpan.textContent = found[1];
    } else if (currentOptions.length > 0) {
      currentValue = currentOptions[0][0];
      hiddenSelect.value = currentValue;
      labelSpan.textContent = currentOptions[0][1];
    } else {
      labelSpan.textContent = "";
    }
  };

  return btn;
}

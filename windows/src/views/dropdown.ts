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

function closeActive() {
  if (activeTrigger) {
    activeTrigger.classList.remove("open");
    activeTrigger = null;
  }
  if (activePanel) {
    activePanel.style.opacity = "0";
    activePanel.style.transform = "scale(0.96) translateY(-4px)";
    const panel = activePanel;
    setTimeout(() => panel.remove(), 150);
    activePanel = null;
  }
}

/** Creates and returns a dropdown menu controller. */
export function dropdown(items: DropdownEntry[]) {
  function buildPanel(): HTMLElement {
    const panel = h("div", { class: "dd-panel", role: "menu" });

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
        ...(item.disabled ? { "aria-disabled": "true" } : {}),
        onclick: () => {
          if (!item.disabled) {
            closeActive();
            item.onClick();
          }
        },
      });

      // Check indicator column (always present for alignment; visible when checked).
      const checkCol = h("span", { class: "dd-check-col", "aria-hidden": "true" });
      if (item.checked) checkCol.append(checkSvg());
      btn.append(checkCol);

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

    const panel = buildPanel();
    panel.style.opacity = "0";
    panel.style.transform = "scale(0.96) translateY(-4px)";
    document.body.append(panel);
    activePanel = panel;

    // Position: below the anchor by default, flip up if near bottom edge.
    const rect = anchor.getBoundingClientRect();
    const panelW = 220;
    let left = rect.left;
    let top = rect.bottom + 6;

    // Flip left if overflows right edge.
    if (left + panelW > window.innerWidth - 8) left = rect.right - panelW;
    if (left < 8) left = 8;

    // Flip up if overflows bottom.
    const panelH = items.length * 36;
    if (top + panelH > window.innerHeight - 8) top = rect.top - panelH - 6;

    panel.style.left = `${left}px`;
    panel.style.top = `${top}px`;

    // Animate in.
    requestAnimationFrame(() => {
      panel.style.opacity = "1";
      panel.style.transform = "scale(1) translateY(0)";
    });

    // Close on outside click / Escape.
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") { closeActive(); cleanup(); }
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        const btns = Array.from(panel.querySelectorAll<HTMLElement>(".dd-item:not(.dd-disabled)"));
        const idx = btns.indexOf(document.activeElement as HTMLElement);
        const next = e.key === "ArrowDown" ? (idx + 1) % btns.length : (idx - 1 + btns.length) % btns.length;
        btns[next]?.focus();
      }
    };
    const onDown = (e: MouseEvent) => {
      if (!panel.contains(e.target as Node)) { closeActive(); cleanup(); }
    };
    function cleanup() {
      document.removeEventListener("keydown", onKey, true);
      document.removeEventListener("mousedown", onDown, true);
    }
    document.addEventListener("keydown", onKey, true);
    document.addEventListener("mousedown", onDown, true);

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

  btn.addEventListener("click", () => {
    if (isDisabled) return;
    const menu = dropdown(
      currentOptions.map(([id, label]) => ({
        label,
        checked: id === currentValue,
        onClick: () => {
          if (currentValue !== id) {
            currentValue = id;
            labelSpan.textContent = label;
            onChange?.(id);
            btn.dispatchEvent(new Event("change", { bubbles: true }));
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
      btn.classList.toggle("dd-disabled", d);
      if (d) btn.setAttribute("disabled", "true");
      else btn.removeAttribute("disabled");
    },
    configurable: true,
  });

  btn.setOptions = (nextOptions: [T, string][]) => {
    currentOptions = [...nextOptions];
    const found = currentOptions.find(([id]) => id === currentValue);
    if (found) {
      labelSpan.textContent = found[1];
    } else if (currentOptions.length > 0) {
      currentValue = currentOptions[0][0];
      labelSpan.textContent = currentOptions[0][1];
    } else {
      labelSpan.textContent = "";
    }
  };

  return btn;
}

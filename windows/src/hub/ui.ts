// Small pieces the Coucou window's pages are drawn with: icons, rows, cards,
// switches, segmented controls. Same look as the Mac's (FlowHub.swift).

import { h } from "../views/dom";
import { t } from "../i18n/i18n";
import type { FlowKey } from "../core/flow";

/** Stroke icons on a 24×24 grid, standing in for the Mac's SF Symbols. */
export const HUB_ICONS: Record<string, string> = {
  mic: "M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3zM5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3",
  record: "M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z",
  chart: "M5 20v-7M10 20V6M15 20v-9M20 20V9",
  book: "M5 4.5h10a3 3 0 0 1 3 3V20H8a3 3 0 0 1-3-3V4.5zM5 17a3 3 0 0 1 3-3h10",
  bolt: "M13 3 5 13h6l-1 8 8-10h-6l1-8z",
  text: "M3.5 18 8 6l4.5 12M5 14h6M17.5 11a2.8 2.8 0 1 0 0 5.6 2.8 2.8 0 0 0 0-5.6zM20.3 10.8V18",
  sliders: "M4 7h9M17 7h3M4 17h3M11 17h9M15 5v4M9 15v4",
  gear: "M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 2.8v2.4M12 18.8v2.4M2.8 12h2.4M18.8 12h2.4M5.5 5.5l1.7 1.7M16.8 16.8l1.7 1.7M5.5 18.5l1.7-1.7M16.8 7.2l1.7-1.7",
  grid: "M4.5 4.5h6v6h-6zM13.5 4.5h6v6h-6zM4.5 13.5h6v6h-6zM13.5 13.5h6v6h-6z",
  terminal: "M3.5 5.5h17v13h-17zM7 10l3 2.5L7 15M12.5 15H17",
  chat: "M4 5.5h16v10H10l-4 3.5v-3.5H4z",
  puzzle: "M9 4h4v2a1.8 1.8 0 1 0 3.6 0V4H20v5.5h-2a1.8 1.8 0 1 0 0 3.6h2V20h-5.5v-2a1.8 1.8 0 1 0-3.6 0v2H4v-6.4h2a1.8 1.8 0 1 0 0-3.6H4V4h5z",
  phone: "M8 2.8h8a1.6 1.6 0 0 1 1.6 1.6v15.2a1.6 1.6 0 0 1-1.6 1.6H8a1.6 1.6 0 0 1-1.6-1.6V4.4A1.6 1.6 0 0 1 8 2.8zM11 18h2",
  wave: "M4 10v4M8 7v10M12 4v16M16 7v10M20 10v4",
  keyboard: "M3 6.5h18v11H3zM6.5 10h1M10 10h1M13.5 10h1M17 10h.5M7 14h10",
  copy: "M8.5 8.5h11v11.5h-11zM5 15.5V4h11",
  trash: "M5 7h14M10 4h4M7 7l1 13h8l1-13M10 11v6M14 11v6",
  x: "M6.5 6.5l11 11M17.5 6.5l-11 11",
  plus: "M12 5v14M5 12h14",
  pencil: "M4.5 19.5l4-1 10.5-10.5-3-3L5.5 15.5l-1 4z",
  download: "M12 4v11M7 10l5 5 5-5M5 20h14",
  check: "M5 12.5 9.5 17 19 7.5",
  dots: "M6 12h.01M12 12h.01M18 12h.01",
  lock: "M6.5 11h11v9h-11zM8.5 11V8a3.5 3.5 0 0 1 7 0v3",
  window: "M3.5 5h17v14h-17zM3.5 9h17",
};

export function icon(name: string): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", HUB_ICONS[name] ?? "");
  svg.append(path);
  return svg;
}

export function iconButton(name: string, title: string, onclick: () => void): HTMLElement {
  const b = h("button", { class: "hub-icon", title, "aria-label": title, onclick });
  b.append(icon(name));
  return b;
}

export function label(text: string): HTMLElement {
  return h("div", { class: "hub-label", text });
}

export function card(...children: (HTMLElement | null | false)[]): HTMLElement {
  const el = h("div", { class: "hub-card" });
  for (const c of children) if (c) el.append(c);
  return el;
}

export function divider(): HTMLElement {
  return h("div", { class: "hub-divider" });
}

export function row(title: string, detail: string | null, ...trailing: (HTMLElement | null)[]): HTMLElement {
  const text = h("div", { class: "text" }, h("div", { class: "title", text: title }));
  if (detail) text.append(h("div", { class: "detail", text: detail }));
  const el = h("div", { class: "hub-row" }, text);
  for (const t of trailing) if (t) el.append(t);
  return el;
}

export function keycap(text: string): HTMLElement {
  return h("span", { class: "hub-keycap", text });
}

export function button(text: string, onclick: () => void, kind: "" | "primary" | "danger" = "", small = false): HTMLButtonElement {
  return h("button", {
    class: ["hub-btn", kind, small ? "small" : ""].filter(Boolean).join(" "),
    text,
    onclick,
  }) as HTMLButtonElement;
}

/** The settings window's switch, so both windows look alike. */
export function toggle(on: boolean, onChange: (v: boolean) => void): HTMLElement {
  const el = h("button", { class: on ? "switch on" : "switch", "aria-pressed": on });
  el.addEventListener("click", () => {
    const next = !el.classList.contains("on");
    el.classList.toggle("on", next);
    el.setAttribute("aria-pressed", String(next));
    onChange(next);
  });
  return el;
}

export function segmented<T extends string>(options: [T, string][], value: T, onChange: (v: T) => void): HTMLElement {
  const el = h("div", { class: "hub-segmented" });
  for (const [id, text] of options) {
    const b = h("button", { class: id === value ? "on" : "", text });
    b.addEventListener("click", () => {
      for (const other of el.querySelectorAll("button")) other.classList.toggle("on", other === b);
      onChange(id);
    });
    el.append(b);
  }
  return el;
}

export function select<T extends string>(options: [T, string][], value: T, onChange: (v: T) => void): HTMLSelectElement {
  const el = h("select", { class: "hub-select" }) as HTMLSelectElement;
  for (const [id, text] of options) el.append(h("option", { value: id, text }));
  el.value = value;
  el.addEventListener("change", () => onChange(el.value as T));
  return el;
}

/** "Right Ctrl", "Ctrl + Win"… */
export function keyLabel(key: FlowKey | "wayland" | "", platform: "windows" | "linux" = "windows"): string {
  switch (key) {
    case "right_alt":
      return t("Right {0}", { 0: "Alt" });
    case "right_shift":
      return t("Right {0}", { 0: "Shift" });
    case "left_ctrl_super":
      return platform === "windows" ? "Ctrl + Win" : "Ctrl + Super";
    case "wayland":
      // Held by the desktop (GlobalShortcuts portal): the keys Coucou suggests.
      return "Ctrl+Alt+V";
    default:
      return t("Right {0}", { 0: "Ctrl" });
  }
}

/** The key written as keycaps: "Right Ctrl" twice for hands-free. */
export function keyKeycap(key: FlowKey | "wayland" | "", platform: "windows" | "linux", twice = false): HTMLElement {
  const label = keyLabel(key, platform);
  return keycap(twice ? `${label} ${label}` : label);
}

/** A number written the way the language writes it. */
export function number(n: number, digits = 0): string {
  try {
    return new Intl.NumberFormat(document.documentElement.lang || undefined, { maximumFractionDigits: digits }).format(n);
  } catch {
    return String(Math.round(n));
  }
}

/** 36 800 → "36.8 k": short numbers for the stat cards. */
export function shortCount(n: number): string {
  if (n < 10_000) return number(n);
  const k = n / 1000;
  return `${number(k >= 100 ? Math.round(k) : Math.round(k * 10) / 10, 1)} k`;
}

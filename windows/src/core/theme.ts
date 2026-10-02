import type { ThemeMode } from "./state";

export type { ThemeMode };
export type ResolvedTheme = "light" | "dark";

export interface ThemePalette {
  islandBg: string;
  card: string;
  cardFlat: string;
  ink: string;
  ink2: string;
  dim: string;
  dim2: string;
  onInk: string;
  overlay1: string;
  overlay2: string;
  overlay3: string;
  overlayStrong: string;
  sparkRgb: string;
  mochiOutline: string;
}

const DARK_PALETTE: ThemePalette = {
  islandBg: "#000000",
  card: "#141518",
  cardFlat: "#0e0f11",
  ink: "#f5f6f8",
  ink2: "#f1f2f4",
  dim: "#9398a1",
  dim2: "#8e939c",
  onInk: "#0b0c0e",
  overlay1: "rgba(255,255,255,0.07)",
  overlay2: "rgba(255,255,255,0.14)",
  overlay3: "rgba(255,255,255,0.2)",
  overlayStrong: "rgba(255,255,255,0.35)",
  sparkRgb: "255,255,255",
  mochiOutline: "rgba(0,0,0,0)",
};

let palette: ThemePalette = { ...DARK_PALETTE };
let resolved: ResolvedTheme = "dark";
let currentMode: ThemeMode = "system";
let media: MediaQueryList | null = null;

const listeners = new Set<() => void>();

export const getTheme = (): ResolvedTheme => resolved;
export const getPalette = (): ThemePalette => palette;

export function onThemeChange(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function systemTheme(): ResolvedTheme {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") return "dark";
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function css(name: string, fallback: string): string {
  if (typeof window === "undefined" || typeof getComputedStyle !== "function") return fallback;
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return value || fallback;
}

function refreshPalette() {
  const d = DARK_PALETTE;
  palette = {
    islandBg: css("--island-bg", d.islandBg),
    card: css("--card", d.card),
    cardFlat: css("--card-flat", d.cardFlat),
    ink: css("--ink", d.ink),
    ink2: css("--ink-2", d.ink2),
    dim: css("--dim", d.dim),
    dim2: css("--dim-2", d.dim2),
    onInk: css("--on-ink", d.onInk),
    overlay1: css("--overlay-1", d.overlay1),
    overlay2: css("--overlay-2", d.overlay2),
    overlay3: css("--overlay-3", d.overlay3),
    overlayStrong: css("--overlay-strong", d.overlayStrong),
    sparkRgb: css("--spark-rgb", d.sparkRgb),
    mochiOutline: css("--mochi-outline", d.mochiOutline),
  };
}

function ensureMediaListener() {
  if (media || typeof window === "undefined" || typeof window.matchMedia !== "function") return;
  media = window.matchMedia("(prefers-color-scheme: dark)");
  media.addEventListener("change", () => {
    if (currentMode === "system") applyTheme("system");
  });
}

export function applyTheme(mode: ThemeMode) {
  currentMode = mode;
  const next = mode === "system" ? systemTheme() : mode;
  const changed = next !== resolved;
  resolved = next;

  const root = document.documentElement;
  root.dataset.theme = next;
  root.style.colorScheme = next;
  refreshPalette();
  ensureMediaListener();

  if (changed) for (const fn of listeners) fn();
}

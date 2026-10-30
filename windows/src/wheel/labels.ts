// What each choice on the wheel says, and its icon (stroked, on a 24 grid).
// Formats keep their own names (JPG, WEBP); tools and actions are translated.

import { t } from "../i18n/i18n";

export type RingName = "convert" | "tools" | "actions";

/** Tools that open the editor window (one image). */
export const EDITOR_TOOLS = new Set(["crop", "edit", "annotate", "redact", "background", "trim"]);

const ICON: Record<string, string> = {
  compress: "M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5",
  metadata: "M3.8 12.6V4.2h8.4l8 8-8.4 8.4zM8.3 8.3h.01",
  crop: "M7 3v14h14M3 7h14v14",
  edit: "M5 7h8M17 7h2M5 12h2M11 12h8M5 17h10M19 17h0M15 5v4M9 10v4M17 15v4",
  annotate: "M4.5 19.5l1-4 10-10 3 3-10 10zM13.5 7.5l3 3",
  redact: "M3 12s3.5-6 9-6 9 6 9 6-3.5 6-9 6-9-6-9-6zM9.5 12a2.5 2.5 0 1 0 5 0 2.5 2.5 0 0 0-5 0M4 4l16 16",
  background: "M4.5 5.5h15v13h-15zM8 15l3-3 2 2 3-3 3 3",
  mergePdf: "M7.5 3.5h8l3 3v11h-11zM4.5 7v13.5h11",
  trim: "M6.5 4a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5zM6.5 15a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5zM8.6 8 19.5 18M8.6 16 19.5 6",
  mute: "M4 9.5h3.5L12 5.5v13l-4.5-4H4zM15.5 9.5l5 5M20.5 9.5l-5 5",
  copy: "M8.6 8.6h10.8v10.8H8.6zM15.4 8.6V4.6H4.6v10.8h4",
  copyPath: "M6 3.5h9l3 3v14H6zM9 10h6M9 14h6M9 18h3",
  move: "M3.5 6.5h6l2 2h9v11h-17zM9.5 14h7M13.5 11l3 3-3 3",
  terminal: "M3.5 5h17v14h-17zM7.5 9.5l3 2.5-3 2.5M12.5 15h4",
  reveal: "M3.5 6.5h6l2 2h9v11h-17zM13.5 15.5a2.3 2.3 0 1 0 .01 0M15.6 17.2l1.9 1.9",
};

export function iconFor(id: string): string | null {
  return ICON[id] ?? null;
}

export function labelFor(ring: RingName, id: string): string {
  if (ring === "convert") return id.toUpperCase();
  switch (id) {
    case "compress":
      return t("Compress");
    case "metadata":
      return t("Metadata");
    case "crop":
      return t("Crop");
    case "edit":
      return t("Edit");
    case "annotate":
      return t("Annotate");
    case "redact":
      return t("Redact");
    case "background":
      return t("Background");
    case "mergePdf":
      return t("One PDF");
    case "trim":
      return t("Trim");
    case "mute":
      return t("No sound");
    case "copy":
      return t("Copy");
    case "copyPath":
      return t("Copy path");
    case "move":
      return t("Move");
    case "terminal":
      return t("Terminal");
    case "reveal":
      return t("Show");
    default:
      return id;
  }
}

export function ringLabel(ring: RingName): string {
  switch (ring) {
    case "convert":
      return t("Convert");
    case "tools":
      return t("Tools");
    case "actions":
      return t("Actions");
  }
}

export const COMPRESS_LEVELS: [string, () => string][] = [
  ["high", () => t("High quality")],
  ["balanced", () => t("Balanced")],
  ["small", () => t("Smallest")],
];

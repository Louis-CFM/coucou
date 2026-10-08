// A colour of your own for each pill's Mochi — the pure half, port of
// NotchBuddy/Sources/CoucouKit/PillColors.swift. The catalog (./pills.ts) keeps
// every default; the `pillColors` preference holds only what the user changed,
// by pill ID, so an empty one paints the island exactly as the catalog says.

/**
 * What the palette offers, in the order it is shown. Every colour is one the
 * catalog already uses, and all of them stay readable on the island's black
 * with Mochi's dark eyes — which a free colour picker could not promise.
 * Same list as PillColors.palette on macOS.
 */
export const PILL_PALETTE: readonly string[] = [
  "#F5F6F8", "#F4505E", "#F29B38", "#FACC15", "#4ADE80",
  "#2DD4BF", "#38BDF8", "#818CF8", "#C084FC", "#E879F9",
];

/** "#RRGGBB" in upper case, or null for anything that is not six hex digits. */
export function normalizeHex(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const m = /^#?([0-9a-fA-F]{6})$/.exec(raw.trim());
  return m ? `#${m[1].toUpperCase()}` : null;
}

/**
 * A stored preference → pill ID → colour. Whatever is not a colour is left
 * out, so a hand-edited or damaged settings.json costs one pill its colour and
 * nothing else. IDs are not checked against the catalog: a pill this build
 * does not know keeps the colour a newer one gave it.
 */
export function parsePillColors(raw: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw == null || typeof raw !== "object" || Array.isArray(raw)) return out;
  for (const [id, value] of Object.entries(raw)) {
    const hex = normalizeHex(value);
    if (id && hex) out[id] = hex;
  }
  return out;
}

/** The colour a pill is painted with: the user's when there is one, else the catalog's. */
export function pillColor(id: string, catalogColor: string, colors: unknown): string {
  return parsePillColors(colors)[id] ?? catalogColor;
}

/**
 * The preference once `hex` is picked for a pill. Picking nothing, something
 * that is not a colour, or the pill's own catalog colour clears the entry: the
 * preference never stores a default.
 */
export function withPillColor(
  colors: unknown, id: string, hex: string | null, catalogColor: string,
): Record<string, string> {
  const next = parsePillColors(colors);
  const picked = normalizeHex(hex);
  if (picked && picked !== normalizeHex(catalogColor)) next[id] = picked;
  else delete next[id];
  return next;
}

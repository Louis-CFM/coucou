// The font and text size of your own — the pure half of Settings → General →
// Font and Text size (Windows and Linux; the Mac has no counterpart). The
// `fontFamily` and `fontScale` preferences hold only what the user changed, so
// an empty family and a factor of 1 leave the stylesheets exactly as shipped.
//
// Both reach the page as CSS variables on <html>: `--font`, the family put in
// front of the stack style.css and settings.css already carry, so a character
// the chosen font lacks still falls back to the fonts that cover it; and
// `--fs`, the factor every font size in those two files is multiplied by.

/** The smallest, the largest and the step of the Text size slider, as a factor. */
export const FONT_SCALE_MIN = 0.85;
export const FONT_SCALE_MAX = 1.3;
export const FONT_SCALE_STEP = 0.05;

/**
 * The stack the stylesheets declare for `--font` (same list as `:root` in
 * style.css and settings.css). The chosen font goes in front of it.
 */
const DEFAULT_STACK =
  `system-ui, "Segoe UI Variable Text", "Segoe UI", "Segoe UI Emoji", "Nirmala UI", ` +
  `"Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans", "Noto Sans Devanagari", "Noto Sans Bengali", ` +
  `"Noto Sans Arabic", "Noto Sans CJK SC", "Noto Sans SC", "Droid Sans Fallback", sans-serif`;

/** What the Font field offers when the system's own list can't be read. */
export const COMMON_FONTS = [
  "Segoe UI", "Segoe UI Variable", "Arial", "Calibri", "Cambria", "Candara", "Consolas",
  "Georgia", "Tahoma", "Trebuchet MS", "Verdana", "Cascadia Code", "Cascadia Mono",
  "Ubuntu", "Cantarell", "Noto Sans", "DejaVu Sans", "Liberation Sans",
];

/**
 * A stored preference → a family name that is safe inside a CSS string, or ""
 * for "no choice". Quotes, backslashes, semicolons, braces and control
 * characters are what could end the declaration early, so they are dropped: a
 * hand-edited or damaged settings.json costs the font and nothing else.
 */
export function cleanFontFamily(raw: unknown): string {
  if (typeof raw !== "string") return "";
  return raw
    .replace(/[\u0000-\u001f\u007f"'\;{}<>]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 80);
}

/**
 * A stored preference → a factor inside the slider's range, in whole steps.
 * Whatever is not a number reads as 1, the size that ships.
 */
export function cleanFontScale(raw: unknown): number {
  if (typeof raw !== "number" || !Number.isFinite(raw)) return 1;
  const clamped = Math.min(FONT_SCALE_MAX, Math.max(FONT_SCALE_MIN, raw));
  return Number((Math.round(clamped / FONT_SCALE_STEP) * FONT_SCALE_STEP).toFixed(2));
}

/** The value of `--font` for a family: the stack itself when none is picked. */
export function fontStack(family: string): string {
  const name = cleanFontFamily(family);
  return name ? `"${name}", ${DEFAULT_STACK}` : DEFAULT_STACK;
}

/**
 * Puts the font and the text size on `root` (the page's <html>). The island and
 * the settings window both call it, at launch and on every settings-changed.
 * A default is taken off again rather than written, so the stylesheets' own
 * `--font` and a missing `--fs` stay what they ship as.
 */
export function applyFont(
  settings: { fontFamily?: string; fontScale?: number },
  root: { style: { setProperty(k: string, v: string): void; removeProperty(k: string): void } } =
    document.documentElement,
) {
  const family = cleanFontFamily(settings.fontFamily);
  if (family) root.style.setProperty("--font", fontStack(family));
  else root.style.removeProperty("--font");
  const scale = cleanFontScale(settings.fontScale);
  if (scale === 1) root.style.removeProperty("--fs");
  else root.style.setProperty("--fs", String(scale));
}

/** One saved appearance for the island and Settings; never changes desktop transparency. */
export type Theme = "light" | "dark";
export function normalizeTheme(value: unknown): Theme { return value === "light" ? "light" : "dark"; }
export function applyTheme(value: unknown, root = document.documentElement): Theme {
  const theme = normalizeTheme(value);
  root.dataset.theme = theme;
  return theme;
}
export function nextTheme(value: unknown): Theme { return normalizeTheme(value) === "dark" ? "light" : "dark"; }

// Fonts that carry the scripts of the ten interface languages, appended to the
// existing stacks before the generic family. Latin and Cyrillic text keeps
// rendering in the fonts it always had; these only fill in the characters
// those lack: Devanagari and Bengali (Nirmala UI), Simplified Chinese
// (Microsoft YaHei) and Arabic (Segoe UI, already first) on Windows, the Noto
// families on Linux.
export const SCRIPT_FONTS =
  `"Nirmala UI", "Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans", "Noto Sans Devanagari", ` +
  `"Noto Sans Bengali", "Noto Sans Arabic", "Noto Sans CJK SC", "Noto Sans SC", "Droid Sans Fallback"`;

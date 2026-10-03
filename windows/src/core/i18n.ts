// Which language the island's own wording is in: the one chosen in the settings,
// or the system's. The chat's answer language is decided on the Rust side.

import { State } from "./state";

/** The locale to format with, e.g. "de-DE". */
export function uiLocale(): string {
  return State.settings.language === "auto" ? navigator.language : State.settings.language;
}

/** The entry of `table` for the UI language, English where there is none. */
export function localized<T>(table: Record<string, T> & { en: T }): T {
  return table[uiLocale().slice(0, 2).toLowerCase()] ?? table.en;
}

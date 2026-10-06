// Key event → combo string in the spelling Rust stores ("Ctrl+Alt+Space").
// Rust (hotkeys::normalize) has the final say; this only turns a key press
// into text, so it can be tested without a browser.

export interface KeyLike {
  key: string;
  code: string;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  metaKey: boolean;
}

const NAMED: Record<string, string> = {
  Space: "Space", Enter: "Enter", Tab: "Tab", Backspace: "Backspace", Delete: "Delete", Insert: "Insert",
  Home: "Home", End: "End", PageUp: "PageUp", PageDown: "PageDown",
  ArrowUp: "Up", ArrowDown: "Down", ArrowLeft: "Left", ArrowRight: "Right",
  Comma: "Comma", Period: "Period", Slash: "Slash", Backslash: "Backslash", Semicolon: "Semicolon",
  Quote: "Quote", BracketLeft: "BracketLeft", BracketRight: "BracketRight", Minus: "Minus", Equal: "Equal",
  Backquote: "Backquote", Pause: "Pause",
  // Keys an Fn combination usually sends (Fn itself never reaches Windows).
  PrintScreen: "PrintScreen", ScrollLock: "ScrollLock", NumLock: "NumLock", CapsLock: "CapsLock",
  AudioVolumeUp: "VolumeUp", AudioVolumeDown: "VolumeDown", AudioVolumeMute: "VolumeMute",
  VolumeUp: "VolumeUp", VolumeDown: "VolumeDown", VolumeMute: "VolumeMute",
  MediaPlayPause: "MediaPlayPause", MediaStop: "MediaStop", MediaTrackNext: "MediaTrackNext",
  MediaTrackPrevious: "MediaTrackPrevious",
};

/** Fn alone: the browser sees "Fn"/"FnLock" only on a few keyboards, usually nothing. */
export function isFnKey(e: { key: string; code: string }): boolean {
  return e.key === "Fn" || e.key === "FnLock" || e.code === "Fn" || e.code === "FnLock";
}

/** Keys that may be used without Ctrl/Alt/Win: they type nothing on their own. */
export function standsAlone(key: string): boolean {
  return /^F([1-9]|1[0-9]|2[0-4])$/.test(key) || STANDALONE.has(key);
}
const STANDALONE = new Set([
  "PrintScreen", "ScrollLock", "Pause", "VolumeUp", "VolumeDown", "VolumeMute",
  "MediaPlayPause", "MediaStop", "MediaTrackNext", "MediaTrackPrevious",
]);

/** The main key from `code` (layout-independent), or null for a lone modifier. */
export function keyName(code: string): string | null {
  let m = /^Key([A-Z])$/.exec(code);
  if (m) return m[1];
  m = /^Digit([0-9])$/.exec(code);
  if (m) return m[1];
  m = /^Numpad([0-9])$/.exec(code);
  if (m) return `Num${m[1]}`;
  m = /^F([0-9]{1,2})$/.exec(code);
  if (m && Number(m[1]) >= 1 && Number(m[1]) <= 24) return `F${m[1]}`;
  return NAMED[code] ?? null;
}

/** null while only modifiers are held, or for a key Coucou can't bind. */
export function comboFromEvent(e: KeyLike): string | null {
  const key = keyName(e.code);
  if (!key) return null;
  const parts: string[] = [];
  if (e.ctrlKey) parts.push("Ctrl");
  if (e.altKey) parts.push("Alt");
  if (e.shiftKey) parts.push("Shift");
  if (e.metaKey) parts.push("Win");
  parts.push(key);
  return parts.join("+");
}

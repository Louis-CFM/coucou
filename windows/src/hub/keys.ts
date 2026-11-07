// The keys a shortcut of one's own may hold, by their KeyboardEvent.code name:
// the same list as the Rust side's (src-tauri/src/flow/logic.rs, known_code).

export const MAX_COMBO = 4;

const MODIFIERS = ["ControlLeft", "ControlRight", "AltLeft", "AltRight", "ShiftLeft", "ShiftRight", "MetaLeft", "MetaRight"];
const OTHERS = ["Space", "Backquote", "Insert", "Pause", "ScrollLock", "CapsLock", "ContextMenu"];

export function knownCode(code: string): boolean {
  return MODIFIERS.includes(code) || OTHERS.includes(code) ||
    /^Key[A-Z]$/.test(code) || /^Digit[0-9]$/.test(code) || /^F([1-9]|1[0-9]|2[0-4])$/.test(code);
}

/**
 * The keys held together → the shortcut: the known ones, modifiers first
 * (Ctrl, Alt, Shift, Win), then the others in the order pressed; at most four.
 */
export function comboFromKeys(held: string[]): string[] {
  const known = [...new Set(held.filter(knownCode))];
  const mods = MODIFIERS.filter((m) => known.includes(m));
  const rest = known.filter((k) => !MODIFIERS.includes(k));
  return [...mods, ...rest].slice(0, MAX_COMBO);
}

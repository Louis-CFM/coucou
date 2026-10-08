// Keyboard shortcuts — the pure part, port of ShortcutLogic.swift.
//
// Global shortcuts are registered by Rust (src-tauri/src/shortcuts.rs), which
// owns the same table of defaults; tests/shortcuts.test.mjs keeps the two in
// step. This file parses and formats accelerators, turns a key press into one
// (the recorder in Settings), spots duplicates, and maps the keys pressed
// inside the open island to what they do.
//
// Why Ctrl+Alt+Space / A / T / S / G / ← → rather than the Mac's letters: see
// the top of src-tauri/src/shortcuts.rs. In short, Windows reads Ctrl+Alt as
// AltGr, and AltGr+E, Q, M, W, C, the digits and most punctuation type a
// character on at least one of the French, German, Spanish, Italian,
// Portuguese or Brazilian layouts (ALTGR_CHARACTERS below).

// ── Strings shown to the user ─────────────────────────────────────────────────
// English keys: Settings shows them through `t()` (src/i18n). Key names
// (Ctrl, Alt, Space…) are never translated.

import { N_ } from "../i18n/i18n";

export const SHORTCUT_TEXT = {
  toggleIsland: N_("Open or close the island"),
  openChat: N_("Open the chat"),
  goToAlert: N_("Go to the waiting permission or question"),
  jumpToTerminal: N_("Open the terminal"),
  attachFrontWindow: N_("Attach the front window to the chat"),
  nextPill: N_("Next pill"),
  prevPill: N_("Previous pill"),
  muteToggle: N_("Mute or unmute Mochi"),
  desktopToggle: N_("Send Mochi to the desktop"),
  wardrobeToggle: N_("Open the wardrobe"),
  island: {
    nextPrev: N_("Next or previous pill"),
    byNumber: N_("Go to pill 1 to 9"),
    send: N_("Send the message"),
    newChat: N_("Start a new chat"),
    settings: N_("Open Settings"),
    pin: N_("Keep the island open"),
    close: N_("Close the island"),
  },
} as const;

// ── Actions ───────────────────────────────────────────────────────────────────

/** Mac `ShortcutAction` raw values. Stored in settings.json: never rename one. */
export type ShortcutId =
  | "toggleIsland"
  | "openChat"
  | "goToAlert"
  | "jumpToTerminal"
  | "attachFrontWindow"
  | "nextPill"
  | "prevPill"
  | "muteToggle"
  | "desktopToggle"
  | "wardrobeToggle";

export interface ShortcutDef {
  id: ShortcutId;
  defaultKeys: string;
  enabledByDefault: boolean;
  /** False for the Mac actions this version can't do yet: reserved, never registered. */
  ported: boolean;
}

const def = (id: ShortcutId, defaultKeys: string, enabledByDefault: boolean, ported: boolean): ShortcutDef =>
  ({ id, defaultKeys, enabledByDefault, ported });

/** Same order and defaults as ACTIONS in src-tauri/src/shortcuts.rs. */
export const SHORTCUTS: readonly ShortcutDef[] = [
  def("toggleIsland", "Ctrl+Alt+N", false, true),
  def("openChat", "Ctrl+Alt+Space", true, true),
  def("goToAlert", "Ctrl+Alt+A", true, true),
  def("jumpToTerminal", "Ctrl+Alt+T", true, true),
  def("attachFrontWindow", "Ctrl+Alt+F", true, false),
  def("nextPill", "Ctrl+Alt+Right", true, true),
  def("prevPill", "Ctrl+Alt+Left", true, true),
  def("muteToggle", "Ctrl+Alt+S", true, true),
  def("desktopToggle", "Ctrl+Alt+D", true, false),
  def("wardrobeToggle", "Ctrl+Alt+G", true, true),
];

export interface Binding {
  /** Canonical accelerator, e.g. "Ctrl+Alt+Space"; empty for no key. */
  keys: string;
  enabled: boolean;
}

/** `settings.shortcuts`: only the actions the user changed. */
export type Bindings = Record<string, Binding>;

/** The binding in force: what the user stored, or the default. */
export function effective(d: ShortcutDef, stored: Bindings | undefined): Binding {
  const own = stored?.[d.id];
  return own ? { keys: own.keys, enabled: own.enabled } : { keys: d.defaultKeys, enabled: d.enabledByDefault };
}

// ── Accelerators ──────────────────────────────────────────────────────────────

export interface Combo {
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  /** The Windows key / Super. */
  meta: boolean;
  /** Canonical key name (see KEY_NAMES). */
  key: string;
}

const PUNCTUATION: Record<string, string> = {
  Comma: ",", Period: ".", Slash: "/", Semicolon: ";", Quote: "'", Backquote: "`",
  BracketLeft: "[", BracketRight: "]", Backslash: "\\", Minus: "-", Equal: "=",
};

const NAMED = [
  "Space", "Enter", "Tab", "Backspace", "Delete", "Insert", "Home", "End",
  "PageUp", "PageDown", "Up", "Down", "Left", "Right",
];

/** Every main key an accelerator may name — all of them parse in Rust too. */
export const KEY_NAMES: readonly string[] = [
  ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
  ...Array.from({ length: 24 }, (_, i) => `F${i + 1}`),
  ...NAMED,
  ...Object.keys(PUNCTUATION),
];

const KEY_ALIASES: Record<string, string> = {
  ARROWUP: "Up", ARROWDOWN: "Down", ARROWLEFT: "Left", ARROWRIGHT: "Right",
  RETURN: "Enter", ESC: "Escape", DEL: "Delete", " ": "Space",
  ...Object.fromEntries(Object.entries(PUNCTUATION).map(([name, ch]) => [ch, name])),
};

function canonicalKey(token: string): string | null {
  const up = token.toUpperCase();
  if (KEY_ALIASES[token]) return KEY_ALIASES[token];
  if (KEY_ALIASES[up]) return KEY_ALIASES[up];
  if (/^KEY[A-Z]$/.test(up)) return up.slice(3);
  if (/^DIGIT[0-9]$/.test(up)) return up.slice(5);
  return KEY_NAMES.find((k) => k.toUpperCase() === up) ?? null;
}

/**
 * "Ctrl+Alt+Space" → a Combo. Accepts the spellings Rust accepts (Control,
 * Option, Super/Cmd, ArrowLeft…). `null` for anything else, and for a bare key:
 * a global shortcut always needs Ctrl, Alt or the Windows key.
 */
export function parseKeys(text: string): Combo | null {
  if (!text.trim()) return null;
  // "Ctrl+Alt++" doesn't happen: the plus key is spelled Equal.
  const tokens = text.split("+").map((t) => t.trim());
  if (tokens.some((t) => !t)) return null;
  const combo: Combo = { ctrl: false, alt: false, shift: false, meta: false, key: "" };
  for (const [i, token] of tokens.entries()) {
    const last = i === tokens.length - 1;
    switch (token.toUpperCase()) {
      case "CTRL": case "CONTROL": case "COMMANDORCONTROL": case "CMDORCTRL":
        if (last) return null;
        combo.ctrl = true;
        continue;
      case "ALT": case "OPTION":
        if (last) return null;
        combo.alt = true;
        continue;
      case "SHIFT":
        if (last) return null;
        combo.shift = true;
        continue;
      case "SUPER": case "META": case "WIN": case "CMD": case "COMMAND":
        if (last) return null;
        combo.meta = true;
        continue;
    }
    if (!last) return null;
    const key = canonicalKey(token);
    if (!key || key === "Escape") return null;
    combo.key = key;
  }
  if (!combo.key || !(combo.ctrl || combo.alt || combo.meta)) return null;
  return combo;
}

/** Combo → "Ctrl+Alt+Shift+Super+Key", the form stored and handed to Rust. */
export function formatKeys(c: Combo): string {
  const parts: string[] = [];
  if (c.ctrl) parts.push("Ctrl");
  if (c.alt) parts.push("Alt");
  if (c.shift) parts.push("Shift");
  if (c.meta) parts.push("Super");
  parts.push(c.key);
  return parts.join("+");
}

/** Canonical form of an accelerator, or null when it isn't one. */
export function normalizeKeys(text: string): string | null {
  const c = parseKeys(text);
  return c ? formatKeys(c) : null;
}

const KEY_GLYPHS: Record<string, string> = { Up: "↑", Down: "↓", Left: "←", Right: "→", ...PUNCTUATION };

/** What a person reads: "Ctrl+Alt+→", "Ctrl+Shift+K", "Win+Space". */
export function displayKeys(text: string): string {
  const c = parseKeys(text);
  if (!c) return text.trim() ? text : "—";
  const parts: string[] = [];
  if (c.ctrl) parts.push("Ctrl");
  if (c.alt) parts.push("Alt");
  if (c.shift) parts.push("Shift");
  if (c.meta) parts.push("Win");
  parts.push(KEY_GLYPHS[c.key] ?? c.key);
  return parts.join("+");
}

// ── Recording a key press ─────────────────────────────────────────────────────

/** The parts of a KeyboardEvent the recorder reads. */
export interface KeyPress {
  key: string;
  code: string;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  metaKey: boolean;
}

export type Recorded =
  /** Only modifiers so far: keep listening. */
  | { kind: "pending" }
  | { kind: "cancel" }
  | { kind: "clear" }
  | { kind: "keys"; keys: string }
  /** Needs Ctrl, Alt or the Windows key. */
  | { kind: "needsModifier" }
  /** On this keyboard, Ctrl+Alt+key is AltGr and types `typed`. */
  | { kind: "typesCharacter"; typed: string; keys: string }
  | { kind: "unsupported" };

const MODIFIER_KEYS = new Set(["Control", "Alt", "Shift", "Meta", "AltGraph", "OS", "Super", "Hyper"]);

/** The main key of a press, by name. Letters follow the layout, so Ctrl+Alt+A
 *  is the key labelled A on AZERTY too — which is what RegisterHotKey and X11
 *  grab. Everything else goes by its position. */
function pressedKey(e: KeyPress): string | null {
  if (/^[a-z]$/i.test(e.key)) return e.key.toUpperCase();
  if (/^Key[A-Z]$/.test(e.code)) return e.code.slice(3);
  if (/^Digit[0-9]$/.test(e.code)) return e.code.slice(5);
  if (/^Arrow(Up|Down|Left|Right)$/.test(e.code)) return e.code.slice(5);
  if (/^F([1-9]|1[0-9]|2[0-4])$/.test(e.code)) return e.code;
  if (NAMED.includes(e.code) || e.code in PUNCTUATION) return e.code;
  if (e.code === "NumpadEnter") return "Enter";
  return null;
}

/** Turns a key press in the recorder into what to do with it. */
export function recordPress(e: KeyPress): Recorded {
  if (MODIFIER_KEYS.has(e.key)) return { kind: "pending" };
  const bare = !e.ctrlKey && !e.altKey && !e.metaKey && !e.shiftKey;
  if (e.key === "Escape" && bare) return { kind: "cancel" };
  if ((e.key === "Backspace" || e.key === "Delete") && bare) return { kind: "clear" };
  const key = pressedKey(e);
  if (!key) return { kind: "unsupported" };
  if (!(e.ctrlKey || e.altKey || e.metaKey)) return { kind: "needsModifier" };
  const keys = formatKeys({ ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, meta: e.metaKey, key });
  // Ctrl+Alt is AltGr on Windows. When the press typed something other than a
  // plain letter, digit or space, this combination is how the user types it.
  if (e.ctrlKey && e.altKey && !e.metaKey) {
    if (e.key === "Dead") return { kind: "typesCharacter", typed: "´", keys };
    if ([...e.key].length === 1 && !/^[a-z0-9 ]$/i.test(e.key)) {
      return { kind: "typesCharacter", typed: e.key, keys };
    }
  }
  return { kind: "keys", keys };
}

// ── Conflicts ─────────────────────────────────────────────────────────────────

/** Actions whose combination another enabled action also uses. */
export function duplicates(entries: Iterable<[string, string]>): Set<string> {
  const seen = new Map<string, string>();
  const dups = new Set<string>();
  for (const [id, keys] of entries) {
    const norm = normalizeKeys(keys);
    if (!norm) continue;
    const other = seen.get(norm);
    if (other != null) {
      dups.add(id);
      dups.add(other);
    } else {
      seen.set(norm, id);
    }
  }
  return dups;
}

/** The (id, keys) pairs Coucou would register with `stored`. */
export function activeKeys(stored: Bindings | undefined): [string, string][] {
  return SHORTCUTS.filter((d) => d.ported)
    .map((d) => [d.id, effective(d, stored)] as const)
    .filter(([, b]) => b.enabled && b.keys)
    .map(([id, b]) => [id, b.keys]);
}

/**
 * What AltGr (= Ctrl+Alt on Windows) types on the keys of the layouts the
 * defaults were checked against: letters and digits only, the keys a shortcut
 * is likely to use. Standard Windows layouts.
 */
export const ALTGR_CHARACTERS: Record<string, Record<string, string>> = {
  "French (AZERTY)": {
    E: "€", "2": "~", "3": "#", "4": "{", "5": "[", "6": "|", "7": "`", "8": "\\", "9": "^", "0": "@",
  },
  "German (QWERTZ)": { Q: "@", E: "€", M: "µ", "2": "²", "3": "³", "7": "{", "8": "[", "9": "]", "0": "}" },
  Spanish: { E: "€", "1": "|", "2": "@", "3": "#", "4": "~", "5": "€", "6": "¬" },
  Italian: { E: "€", "5": "€" },
  Portuguese: { E: "€", "2": "@", "3": "£", "4": "§", "5": "€", "7": "{", "8": "[", "9": "]", "0": "}" },
  "Brazilian (ABNT2)": {
    Q: "/", W: "?", E: "°", C: "₢", "1": "¹", "2": "²", "3": "³", "4": "£", "5": "¢", "6": "¬",
  },
};

/** The layouts on which `keys` would type a character instead of running. */
export function altGrClashes(keys: string): string[] {
  const c = parseKeys(keys);
  if (!c || !c.ctrl || !c.alt || c.meta) return [];
  return Object.entries(ALTGR_CHARACTERS)
    .filter(([, chars]) => chars[c.key] != null)
    .map(([layout]) => layout);
}

// ── Inside the open island ────────────────────────────────────────────────────

/** Same as ShortcutLogic.navigate: next card-list selection, clamped. */
export function navigate(selection: number | null, delta: number, itemCount: number): number | null {
  if (itemCount <= 0) return null;
  if (selection != null) return Math.max(0, Math.min(itemCount - 1, selection + delta));
  return delta > 0 ? 0 : itemCount - 1;
}

/** The pill `delta` steps from `current`, wrapping around (cyclePill). */
export function cyclePill(ids: readonly string[], current: string | null, delta: number): string | null {
  if (ids.length === 0) return null;
  const at = Math.max(0, current == null ? 0 : ids.indexOf(current));
  return ids[(((at + delta) % ids.length) + ids.length) % ids.length];
}

/** Pill number `n`, counting from 1 (switchToPill). */
export function pillByNumber(ids: readonly string[], n: number): string | null {
  return n >= 1 && n <= ids.length ? ids[n - 1] : null;
}

/** Shown read-only in Settings, like ShortcutLogic.islandShortcuts. The Mac's
 *  ⌘↑ ⌘↓ ⌘O (card lists) and ⌘E (diff) have no counterpart here yet. */
export const ISLAND_SHORTCUTS: readonly { keys: string; description: string }[] = [
  { keys: "Ctrl+→ / Ctrl+←", description: SHORTCUT_TEXT.island.nextPrev },
  { keys: "Ctrl+1 – Ctrl+9", description: SHORTCUT_TEXT.island.byNumber },
  { keys: "Ctrl+Enter", description: SHORTCUT_TEXT.island.send },
  { keys: "Ctrl+K", description: SHORTCUT_TEXT.island.newChat },
  { keys: "Ctrl+,", description: SHORTCUT_TEXT.island.settings },
  { keys: "Ctrl+P", description: SHORTCUT_TEXT.island.pin },
  { keys: "Esc", description: SHORTCUT_TEXT.island.close },
];

export type IslandKeyAction =
  | { kind: "cycle"; delta: 1 | -1 }
  | { kind: "pill"; number: number }
  | { kind: "newChat" }
  | { kind: "settings" }
  | { kind: "pin" };

/**
 * A key pressed while the island has the keyboard → what it does, or null to
 * leave it alone. Ctrl stands in for ⌘. In a text field Ctrl+← and Ctrl+→
 * keep moving by word.
 */
export function islandKeyAction(
  e: KeyPress,
  ctx: { view: string; inTextField: boolean },
): IslandKeyAction | null {
  if (!e.ctrlKey || e.altKey || e.shiftKey || e.metaKey) return null;
  if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
    if (ctx.inTextField) return null;
    return { kind: "cycle", delta: e.key === "ArrowRight" ? 1 : -1 };
  }
  const digit = /^Digit([1-9])$/.exec(e.code);
  if (digit) return { kind: "pill", number: Number(digit[1]) };
  const letter = /^[a-z]$/i.test(e.key) ? e.key.toLowerCase() : /^Key([A-Z])$/.exec(e.code)?.[1].toLowerCase();
  if (letter === "k") return ctx.view === "prompt" ? { kind: "newChat" } : null;
  if (letter === "p") return { kind: "pin" };
  if (e.key === "," || e.code === "Comma") return { kind: "settings" };
  return null;
}

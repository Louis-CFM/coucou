// Keyboard shortcuts: the pure logic (src/core/shortcuts.ts, mirroring the
// Mac's tests/ShortcutTests.swift) and what the island does with them
// (src/island/shortcuts.ts), driven through the real bridge.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { calls, emit, sent } from "./tauri.mjs";
import {
  ALTGR_CHARACTERS, ISLAND_SHORTCUTS, KEY_NAMES, SHORTCUTS, SHORTCUT_TEXT, activeKeys, altGrClashes,
  cyclePill, displayKeys, duplicates, effective, formatKeys, islandKeyAction, navigate, normalizeKeys,
  parseKeys, pillByNumber, recordPress,
} from "../src/core/shortcuts.ts";
import { registerShortcutHandlers, runGlobalShortcut, runIslandKey } from "../src/island/shortcuts.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

const MAC_IDS = [
  "toggleIsland", "openChat", "goToAlert", "jumpToTerminal", "attachFrontWindow",
  "nextPill", "prevPill", "muteToggle", "desktopToggle", "wardrobeToggle",
];

// ── Defaults (testDefaultsExhaustive, testAllDefaultsHaveModifier, testNoDefaultDuplicates) ──

test("every Mac action has a default, in the Mac's order, with its Mac id", () => {
  assert.deepEqual(SHORTCUTS.map((d) => d.id), MAC_IDS);
  for (const d of SHORTCUTS) assert.ok(SHORTCUT_TEXT[d.id], `${d.id} has no label`);
});

test("every default parses, is canonical and holds Ctrl+Alt", () => {
  for (const d of SHORTCUTS) {
    const c = parseKeys(d.defaultKeys);
    assert.ok(c, `${d.id} default does not parse`);
    assert.ok(c.ctrl && c.alt && !c.meta, `${d.id} default is not Ctrl+Alt`);
    assert.equal(formatKeys(c), d.defaultKeys, `${d.id} default is not in canonical form`);
  }
});

test("no two defaults share a combination", () => {
  assert.deepEqual(duplicates(SHORTCUTS.map((d) => [d.id, d.defaultKeys])), new Set());
});

test("no default types a character with AltGr on the checked European layouts", () => {
  for (const layout of ["French (AZERTY)", "German (QWERTZ)", "Spanish", "Italian", "Portuguese", "Brazilian (ABNT2)"]) {
    assert.ok(ALTGR_CHARACTERS[layout], layout);
  }
  for (const d of SHORTCUTS) {
    assert.deepEqual(altGrClashes(d.defaultKeys), [], `${d.id} = ${d.defaultKeys}`);
  }
  // The Mac's own letters would not have been safe.
  assert.deepEqual(altGrClashes("Ctrl+Alt+M"), ["German (QWERTZ)"]);
  assert.ok(altGrClashes("Ctrl+Alt+E").length >= 5);
  assert.ok(altGrClashes("Ctrl+Alt+0").includes("French (AZERTY)"));
  // Not Ctrl+Alt: not AltGr.
  assert.deepEqual(altGrClashes("Ctrl+Shift+E"), []);
});

test("the defaults are the same on both sides of the bridge", () => {
  const rust = readFileSync(new URL("../src-tauri/src/shortcuts.rs", import.meta.url), "utf8");
  const rows = [...rust.matchAll(/^\s*action\("(\w+)", "([^"]+)", (true|false), (true|false)\),/gm)]
    .map(([, id, keys, on, ported]) => ({ id, keys, on: on === "true", ported: ported === "true" }));
  assert.deepEqual(
    rows,
    SHORTCUTS.map((d) => ({ id: d.id, keys: d.defaultKeys, on: d.enabledByDefault, ported: d.ported })),
  );
});

test("the descriptions the Wayland portal shows are the labels Settings shows", () => {
  const rust = readFileSync(new URL("../src-tauri/src/shortcuts.rs", import.meta.url), "utf8");
  const rows = Object.fromEntries(
    [...rust.matchAll(/^\s*"(\w+)" => n_\("([^"]+)"\),/gm)].map(([, id, text]) => [id, text]),
  );
  assert.deepEqual(rows, Object.fromEntries(SHORTCUTS.map((d) => [d.id, SHORTCUT_TEXT[d.id]])));
});

// testEnabledByDefault
test("only the island toggle is off by default; the one not ported yet is reserved", () => {
  for (const d of SHORTCUTS) {
    assert.equal(d.enabledByDefault, d.id !== "toggleIsland", d.id);
    assert.equal(d.ported, d.id !== "attachFrontWindow", d.id);
  }
  assert.deepEqual(activeKeys({}).map(([id]) => id), [
    "openChat", "goToAlert", "jumpToTerminal", "nextPill", "prevPill", "muteToggle", "desktopToggle",
    "wardrobeToggle",
  ]);
  // The Mac's ⌃⌥D, on the same letter.
  assert.equal(SHORTCUTS.find((d) => d.id === "desktopToggle").defaultKeys, "Ctrl+Alt+D");
});

// ── Parsing and formatting (testCarbonModifiers, testDisplayString, testKeyCodeToString) ──

test("modifiers parse one by one and all together", () => {
  assert.deepEqual(parseKeys("Ctrl+Shift+N"), { ctrl: true, alt: false, shift: true, meta: false, key: "N" });
  assert.deepEqual(parseKeys("Ctrl+Alt+A"), { ctrl: true, alt: true, shift: false, meta: false, key: "A" });
  assert.deepEqual(parseKeys("Super+Shift+Alt+Ctrl+k"), { ctrl: true, alt: true, shift: true, meta: true, key: "K" });
  // The spellings Rust accepts.
  assert.equal(normalizeKeys("control+option+arrowright"), "Ctrl+Alt+Right");
  assert.equal(normalizeKeys("CmdOrCtrl+Alt+KeyQ"), "Ctrl+Alt+Q");
  assert.equal(normalizeKeys("Ctrl+Alt+Digit7"), "Ctrl+Alt+7");
  assert.equal(normalizeKeys("Ctrl+Alt+]"), "Ctrl+Alt+BracketRight");
});

test("a bare key, Shift alone, a modifier with no key, or nonsense is not a shortcut", () => {
  for (const bad of ["", "A", "Shift+A", "Ctrl+Alt", "Ctrl+Alt+", "Ctrl+Alt+Nope", "A+Ctrl", "Ctrl+A+B", "Ctrl+Escape"]) {
    assert.equal(parseKeys(bad), null, JSON.stringify(bad));
  }
});

test("what a person reads", () => {
  assert.equal(displayKeys("Ctrl+Shift+N"), "Ctrl+Shift+N");
  assert.equal(displayKeys("Ctrl+Alt+Space"), "Ctrl+Alt+Space");
  assert.equal(displayKeys("Ctrl+Alt+Right"), "Ctrl+Alt+→");
  assert.equal(displayKeys("Ctrl+Alt+Left"), "Ctrl+Alt+←");
  assert.equal(displayKeys("Super+Comma"), "Win+,");
  assert.equal(displayKeys("Ctrl+Alt+BracketLeft"), "Ctrl+Alt+[");
  assert.equal(displayKeys(""), "—");
  // Each modifier once.
  assert.equal(displayKeys("Ctrl+Ctrl+Alt+A").match(/Ctrl/g).length, 1);
});

test("every key name survives a round trip", () => {
  for (const key of KEY_NAMES) {
    assert.equal(normalizeKeys(`Ctrl+Alt+${key}`), `Ctrl+Alt+${key}`, key);
  }
});

// ── Conflicts (testDuplicateDetection) ───────────────────────────────────────

test("duplicates flag both actions, and only the same modifiers and key", () => {
  assert.deepEqual(duplicates([]), new Set());
  assert.deepEqual(duplicates([["goToAlert", "Ctrl+Alt+A"]]), new Set());
  assert.deepEqual(duplicates([["goToAlert", "Ctrl+Alt+A"], ["jumpToTerminal", "Ctrl+Alt+T"]]), new Set());
  assert.deepEqual(
    duplicates([["goToAlert", "Ctrl+Alt+A"], ["jumpToTerminal", "ctrl+alt+a"]]),
    new Set(["goToAlert", "jumpToTerminal"]),
  );
  assert.deepEqual(duplicates([["goToAlert", "Ctrl+Alt+A"], ["jumpToTerminal", "Ctrl+Shift+A"]]), new Set());
});

// ── Stored bindings (testLoadSaveRoundTrip) ───────────────────────────────────

test("a stored binding wins, the rest keep their default, and off ones hold no keys", () => {
  const stored = {
    openChat: { keys: "Ctrl+Alt+K", enabled: true },
    goToAlert: { keys: "Ctrl+Alt+A", enabled: false },
    toggleIsland: { keys: "Ctrl+Alt+N", enabled: true },
  };
  const chat = SHORTCUTS.find((d) => d.id === "openChat");
  assert.deepEqual(effective(chat, stored), { keys: "Ctrl+Alt+K", enabled: true });
  assert.deepEqual(effective(chat, undefined), { keys: "Ctrl+Alt+Space", enabled: true });
  const ids = activeKeys(stored).map(([id]) => id);
  assert.ok(ids.includes("toggleIsland"));
  assert.ok(!ids.includes("goToAlert"));
  // Same JSON shape as Rust's Bindings.
  assert.deepEqual(JSON.parse(JSON.stringify(stored)).openChat, { keys: "Ctrl+Alt+K", enabled: true });
  assert.deepEqual(DEFAULT_SETTINGS.shortcuts, {});
});

// ── Recording a press ─────────────────────────────────────────────────────────

const press = (over) => ({
  key: "", code: "", ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, ...over,
});

test("the recorder turns a press into canonical keys", () => {
  assert.deepEqual(recordPress(press({ key: " ", code: "Space", ctrlKey: true, altKey: true })),
    { kind: "keys", keys: "Ctrl+Alt+Space" });
  assert.deepEqual(recordPress(press({ key: "ArrowRight", code: "ArrowRight", ctrlKey: true, altKey: true })),
    { kind: "keys", keys: "Ctrl+Alt+Right" });
  // AZERTY: the key labelled A sits where QWERTY has Q. The label wins, as it
  // does for RegisterHotKey.
  assert.deepEqual(recordPress(press({ key: "a", code: "KeyQ", ctrlKey: true, altKey: true })),
    { kind: "keys", keys: "Ctrl+Alt+A" });
  assert.deepEqual(recordPress(press({ key: "K", code: "KeyK", ctrlKey: true, shiftKey: true })),
    { kind: "keys", keys: "Ctrl+Shift+K" });
  assert.deepEqual(recordPress(press({ key: "F9", code: "F9", metaKey: true })),
    { kind: "keys", keys: "Super+F9" });
});

test("the recorder waits for a key, cancels, clears, and refuses what can't be a shortcut", () => {
  assert.deepEqual(recordPress(press({ key: "Control", code: "ControlLeft", ctrlKey: true })), { kind: "pending" });
  assert.deepEqual(recordPress(press({ key: "AltGraph", code: "AltRight", ctrlKey: true, altKey: true })), { kind: "pending" });
  assert.deepEqual(recordPress(press({ key: "Escape", code: "Escape" })), { kind: "cancel" });
  assert.deepEqual(recordPress(press({ key: "Backspace", code: "Backspace" })), { kind: "clear" });
  assert.deepEqual(recordPress(press({ key: "a", code: "KeyA" })), { kind: "needsModifier" });
  assert.deepEqual(recordPress(press({ key: "A", code: "KeyA", shiftKey: true })), { kind: "needsModifier" });
  assert.deepEqual(recordPress(press({ key: "Unidentified", code: "Lang1", ctrlKey: true })), { kind: "unsupported" });
});

test("a Ctrl+Alt press that types a character on this keyboard is refused", () => {
  // German: AltGr+E = €, AltGr+Q = @. French: AltGr+0 = @.
  assert.deepEqual(recordPress(press({ key: "€", code: "KeyE", ctrlKey: true, altKey: true })),
    { kind: "typesCharacter", typed: "€", keys: "Ctrl+Alt+E" });
  assert.deepEqual(recordPress(press({ key: "@", code: "KeyQ", ctrlKey: true, altKey: true })),
    { kind: "typesCharacter", typed: "@", keys: "Ctrl+Alt+Q" });
  assert.deepEqual(recordPress(press({ key: "@", code: "Digit0", ctrlKey: true, altKey: true })),
    { kind: "typesCharacter", typed: "@", keys: "Ctrl+Alt+0" });
  assert.equal(recordPress(press({ key: "Dead", code: "BracketLeft", ctrlKey: true, altKey: true })).kind, "typesCharacter");
  // Ctrl+Shift is never AltGr.
  assert.deepEqual(recordPress(press({ key: "€", code: "KeyE", ctrlKey: true, shiftKey: true })),
    { kind: "keys", keys: "Ctrl+Shift+E" });
});

// ── In the island (testCardNavigation and the island keys) ───────────────────

test("card navigation clamps, and starts from either end", () => {
  assert.equal(navigate(null, +1, 3), 0);
  assert.equal(navigate(null, -1, 3), 2);
  assert.equal(navigate(0, -1, 3), 0);
  assert.equal(navigate(2, +1, 3), 2);
  assert.equal(navigate(1, +1, 3), 2);
  assert.equal(navigate(1, -1, 3), 0);
  assert.equal(navigate(1, 0, 3), 1);
  assert.equal(navigate(null, +1, 0), null);
  assert.equal(navigate(0, +1, 0), null);
});

test("pills cycle around and are picked by number", () => {
  const ids = ["a", "b", "c"];
  assert.equal(cyclePill(ids, "a", 1), "b");
  assert.equal(cyclePill(ids, "c", 1), "a");
  assert.equal(cyclePill(ids, "a", -1), "c");
  assert.equal(cyclePill(ids, "gone", 1), "b");
  assert.equal(cyclePill([], "a", 1), null);
  assert.equal(pillByNumber(ids, 1), "a");
  assert.equal(pillByNumber(ids, 3), "c");
  assert.equal(pillByNumber(ids, 4), null);
  assert.equal(pillByNumber(ids, 0), null);
});

test("Ctrl stands in for ⌘ inside the island", () => {
  const ctx = { view: "overview", inTextField: false };
  const ctrl = (key, code = "") => press({ key, code, ctrlKey: true });
  assert.deepEqual(islandKeyAction(ctrl("ArrowRight"), ctx), { kind: "cycle", delta: 1 });
  assert.deepEqual(islandKeyAction(ctrl("ArrowLeft"), ctx), { kind: "cycle", delta: -1 });
  assert.deepEqual(islandKeyAction(ctrl("&", "Digit1"), ctx), { kind: "pill", number: 1 });
  assert.deepEqual(islandKeyAction(ctrl("9", "Digit9"), ctx), { kind: "pill", number: 9 });
  assert.equal(islandKeyAction(ctrl("0", "Digit0"), ctx), null);
  assert.deepEqual(islandKeyAction(ctrl("p", "KeyP"), ctx), { kind: "pin" });
  assert.deepEqual(islandKeyAction(ctrl(",", "Comma"), ctx), { kind: "settings" });
  // Ctrl+K only means something in the chat.
  assert.equal(islandKeyAction(ctrl("k", "KeyK"), ctx), null);
  assert.deepEqual(islandKeyAction(ctrl("k", "KeyK"), { view: "prompt", inTextField: true }), { kind: "newChat" });
  // In a text field Ctrl+← → move by word.
  assert.equal(islandKeyAction(ctrl("ArrowRight"), { view: "prompt", inTextField: true }), null);
  // Anything with another modifier, or no Ctrl, is left alone.
  assert.equal(islandKeyAction(press({ key: "ArrowRight", ctrlKey: true, altKey: true }), ctx), null);
  assert.equal(islandKeyAction(press({ key: "p", code: "KeyP" }), ctx), null);
  assert.ok(ISLAND_SHORTCUTS.length >= 6);
});

test("Ctrl+↓ ↑ walk a card's list, Ctrl+O opens, Ctrl+E is the overview's diff", () => {
  const ctx = { view: "overview", inTextField: false };
  const ctrl = (key, code = "") => press({ key, code, ctrlKey: true });
  assert.deepEqual(islandKeyAction(ctrl("ArrowDown", "ArrowDown"), ctx), { kind: "list", delta: 1 });
  assert.deepEqual(islandKeyAction(ctrl("ArrowUp", "ArrowUp"), ctx), { kind: "list", delta: -1 });
  assert.deepEqual(islandKeyAction(ctrl("o", "KeyO"), ctx), { kind: "openSelection" });
  assert.deepEqual(islandKeyAction(ctrl("e", "KeyE"), ctx), { kind: "diff" });
  // The key labelled E on any layout, and Ctrl+Shift+E is something else.
  assert.deepEqual(islandKeyAction(ctrl("E", "KeyE"), ctx), { kind: "diff" });
  assert.equal(islandKeyAction(press({ key: "E", code: "KeyE", ctrlKey: true, shiftKey: true }), ctx), null);
  // ⌘E only means something in the overview, where the diff opens.
  assert.equal(islandKeyAction(ctrl("e", "KeyE"), { view: "prompt", inTextField: true }), null);
  // In the chat field Ctrl+↑ ↓ keep moving by paragraph.
  assert.equal(islandKeyAction(ctrl("ArrowDown", "ArrowDown"), { view: "prompt", inTextField: true }), null);
  // Settings lists them in the Mac's order (ShortcutLogic.islandShortcuts).
  assert.deepEqual(ISLAND_SHORTCUTS.map((s) => s.keys).slice(0, 5), [
    "Ctrl+→ / Ctrl+←", "Ctrl+1 – Ctrl+9", "Ctrl+↓ / Ctrl+↑", "Ctrl+O", "Ctrl+E",
  ]);
  assert.equal(SHORTCUT_TEXT.island.navItems, "Navigate list items");
  assert.equal(SHORTCUT_TEXT.island.open, "Open selected item");
  assert.equal(SHORTCUT_TEXT.island.diff, "Open / close current diff");
});

// ── What the island does ──────────────────────────────────────────────────────

let did;
const host = {
  alert: (v) => did.push(`alert:${v}`),
  setView: (v) => did.push(`setView:${v}`),
  collapse: () => did.push("collapse"),
  emote: (e) => did.push(`emote:${e}`),
  setPinned: (on) => did.push(`pin:${on}`),
  takeKeyboard: () => did.push("keyboard"),
  wardrobeAnywhere: () => did.push("wardrobe"),
  canLeaveIsland: () => desktopSupported,
  flyOutOrHome: () => did.push("desktop"),
  viewCommand: (c) => did.push(`view:${c}`),
};
let desktopSupported = true;
const resume = () => did.push("resume");
// The island listens on `window`, which here is the bare global object.
const listeners = [];
globalThis.addEventListener = (type, fn, capture) => listeners.push({ type, fn, capture });
registerShortcutHandlers(host, resume);

beforeEach(() => {
  did = [];
  calls.length = 0;
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.isPinned = false;
  State.pendingApproval = null;
  State.stateOverride = null;
  State.chatHistory = [];
  State.settings = { ...DEFAULT_SETTINGS };
  State.mochiOnDesktop = false;
  State.cardSelection = null;
  State.cardItemCount = 0;
  desktopSupported = true;
  State.loadIntegrationTasks();
});

test("the wardrobe shortcut's own event opens the wardrobe", () => {
  emit("open-wardrobe", null);
  assert.deepEqual(did, ["resume", "wardrobe"]);
});

test("a global shortcut arrives as an event and opens the chat", () => {
  emit("shortcut", "openChat");
  assert.deepEqual(did, ["resume", "alert:prompt"]);
});

test("island keys are read before the chat field sees them, and only while open", () => {
  const keydown = listeners.find((l) => l.type === "keydown");
  assert.equal(keydown.capture, true);
  const ev = (over) => {
    const e = { ...press(over), target: null, stopped: false, prevented: false };
    e.preventDefault = () => { e.prevented = true; };
    e.stopPropagation = () => { e.stopped = true; };
    return e;
  };
  const hidden = ev({ key: "p", code: "KeyP", ctrlKey: true });
  keydown.fn(hidden);
  assert.equal(hidden.prevented, false);

  State.mode = "expanded";
  const pin = ev({ key: "p", code: "KeyP", ctrlKey: true });
  keydown.fn(pin);
  assert.ok(pin.prevented && pin.stopped);
  assert.deepEqual(did, ["pin:true"]);

  // Typing in the chat is left alone, word jumps included.
  const word = ev({ key: "ArrowLeft", ctrlKey: true });
  word.target = { tagName: "INPUT" };
  keydown.fn(word);
  assert.equal(word.prevented, false);
  const plain = ev({ key: "k", code: "KeyK" });
  keydown.fn(plain);
  assert.equal(plain.prevented, false);
});

test("the island toggle opens with the keyboard, and closes an open island", () => {
  runGlobalShortcut(host, "toggleIsland", resume);
  assert.deepEqual(did, ["resume", "alert:overview", "keyboard"]);
  did = [];
  State.mode = "expanded";
  runGlobalShortcut(host, "toggleIsland", resume);
  assert.deepEqual(did, ["collapse"]);
});

test("go to alert: the permission first, then a question, else Mochi is annoyed", () => {
  runGlobalShortcut(host, "goToAlert", resume);
  assert.deepEqual(did, ["emote:annoyed"]);

  did = [];
  State.upsertExternalAgent("agent_gemini", "Gemini", "#fff");
  State.updateTask("agent_gemini", "question");
  runGlobalShortcut(host, "goToAlert", resume);
  assert.deepEqual(did, ["resume", "alert:question", "keyboard"]);
  assert.equal(State.focusId, "agent_gemini");

  did = [];
  State.pendingApproval = { requestId: "r1", sessionId: "s", pillId: "integration_claude", tool: "Bash", command: "ls" };
  runGlobalShortcut(host, "goToAlert", resume);
  assert.deepEqual(did, ["resume", "alert:approval", "keyboard"]);
  assert.equal(State.focusId, "integration_claude");
  // Nothing is ever decided from a shortcut.
  assert.deepEqual(sent("approval_decision"), []);
});

test("go to alert brings up the unified card: any agent's pill, a question as a question", () => {
  State.upsertExternalAgent("agent_codex", "Codex", "#fff");
  State.pendingApproval = { requestId: "r1", sessionId: "s", pillId: "agent_codex", tool: "Bash", command: "ls" };
  runGlobalShortcut(host, "goToAlert", resume);
  assert.deepEqual(did, ["resume", "alert:approval", "keyboard"]);
  assert.equal(State.focusId, "agent_codex");

  did = [];
  State.pendingApproval = {
    requestId: "r2", sessionId: "s", pillId: "integration_claude", tool: "AskUserQuestion", command: "",
    questions: [{ question: "Which?", options: [], multiSelect: false }],
  };
  runGlobalShortcut(host, "goToAlert", resume);
  assert.deepEqual(did, ["resume", "alert:question", "keyboard"]);
  assert.equal(State.focusId, "integration_claude");
  assert.deepEqual(sent("approval_decision"), []);
  assert.deepEqual(sent("approval_answer"), []);
});

test("the island toggle opens on a waiting card, and folds it rather than dropping it", () => {
  State.pendingApproval = { requestId: "r1", sessionId: "s", pillId: "integration_claude", tool: "Bash", command: "ls" };
  runGlobalShortcut(host, "toggleIsland", resume);
  assert.deepEqual(did, ["resume", "alert:approval", "keyboard"]);
  did = [];
  State.mode = "expanded";
  // The island's collapse() folds a waiting card (Island.foldApproval).
  runGlobalShortcut(host, "toggleIsland", resume);
  assert.deepEqual(did, ["collapse"]);
  assert.equal(State.pendingApproval.requestId, "r1");
});

test("the terminal shortcut is the existing Open terminal (the session's window), and folds the island", () => {
  State.tasks[0].sessionCwd = "C:\\work\\proj";
  State.mode = "expanded";
  runGlobalShortcut(host, "jumpToTerminal", resume);
  assert.deepEqual(sent("open_session"), [{ sessionId: null, path: "C:\\work\\proj" }]);
  assert.deepEqual(did, ["collapse"]);

  // A Claude Desktop session lives in the Claude app.
  did = [];
  State.upsertExternalAgent("agent_claude-desktop", "Claude Desktop", "#D97757");
  State.setFocus("agent_claude-desktop");
  runGlobalShortcut(host, "jumpToTerminal", resume);
  assert.equal(sent("open_claude_desktop").length, 1);
});

test("next and previous pill wrap around and open the overview", () => {
  const ids = State.tasks.map((t) => t.id);
  State.focusId = ids[0];
  runGlobalShortcut(host, "prevPill", resume);
  assert.equal(State.focusId, ids[ids.length - 1]);
  runGlobalShortcut(host, "nextPill", resume);
  assert.equal(State.focusId, ids[0]);
  assert.deepEqual(did, ["resume", "alert:overview", "resume", "alert:overview"]);
});

test("mute flips the sound, saves it, and Mochi reacts", () => {
  runGlobalShortcut(host, "muteToggle", resume);
  assert.equal(State.settings.soundEnabled, false);
  assert.equal(sent("save_settings").at(-1).settings.soundEnabled, false);
  runGlobalShortcut(host, "muteToggle", resume);
  assert.equal(State.settings.soundEnabled, true);
  assert.deepEqual(did, ["emote:annoyed", "emote:happy"]);
});

test("the desktop shortcut sends Mochi out, lifting Pause, and brings him home", () => {
  runGlobalShortcut(host, "desktopToggle", resume);
  assert.deepEqual(did, ["resume", "desktop"]);
  // Out there already: home, and Pause stays as it is.
  did = [];
  State.mochiOnDesktop = true;
  runGlobalShortcut(host, "desktopToggle", resume);
  assert.deepEqual(did, ["desktop"]);
  assert.deepEqual(calls, []);
});

test("where Mochi can't leave the island (GNOME on Wayland), he says so", () => {
  desktopSupported = false;
  runGlobalShortcut(host, "desktopToggle", resume);
  assert.deepEqual(did, ["emote:annoyed"]);
});

test("the desktop shortcut arrives like the others, and runs from the command line", () => {
  emit("shortcut", "desktopToggle");
  assert.deepEqual(did, ["resume", "desktop"]);
  const rust = readFileSync(new URL("../src-tauri/src/shortcuts.rs", import.meta.url), "utf8");
  assert.match(rust, /from_args\(&args\(&\["coucou", "--shortcut", "desktopToggle"\]\)\), Some\("desktopToggle"\)/);
});

test("actions that aren't the island's do nothing here", () => {
  for (const id of ["wardrobeToggle", "attachFrontWindow", "nonsense"]) {
    runGlobalShortcut(host, id, resume);
  }
  assert.deepEqual(did, []);
  assert.deepEqual(calls, []);
});

test("island keys: pills by number, new chat, settings, pin", () => {
  const ids = State.tasks.map((t) => t.id);
  runIslandKey(host, { kind: "pill", number: 2 });
  assert.equal(State.focusId, ids[1]);
  runIslandKey(host, { kind: "pill", number: 9 });
  assert.equal(State.focusId, ids[1]);
  runIslandKey(host, { kind: "cycle", delta: 1 });
  assert.equal(State.focusId, ids[2 % ids.length]);

  State.chatHistory = [{ id: 1, role: "user", content: "hi" }];
  State.stateOverride = "thinking";
  runIslandKey(host, { kind: "newChat" });
  assert.equal(State.chatHistory.length, 1, "not while an answer is on its way");
  State.stateOverride = null;
  runIslandKey(host, { kind: "newChat" });
  assert.deepEqual(State.chatHistory, []);
  assert.equal(sent("chat_reset").length, 1);

  runIslandKey(host, { kind: "settings" });
  assert.equal(sent("open_settings_window").length, 1);

  runIslandKey(host, { kind: "pin" });
  State.pendingApproval = { requestId: "r1", sessionId: "s", pillId: "integration_claude", tool: "Bash", command: "ls" };
  runIslandKey(host, { kind: "pin" });
  assert.deepEqual(did, ["setView:overview", "setView:overview", "setView:prompt", "pin:true"]);
});

test("island keys: the highlight walks the list on screen, Ctrl+O opens it, Ctrl+E the diff", () => {
  // No list on screen: nothing to walk, nothing to open.
  runIslandKey(host, { kind: "list", delta: 1 });
  assert.equal(State.cardSelection, null);
  runIslandKey(host, { kind: "openSelection" });
  assert.deepEqual(did, []);

  // A GitHub list of three: from the top, clamped at the bottom (ShortcutLogic.navigate).
  State.cardItemCount = 3;
  runIslandKey(host, { kind: "list", delta: 1 });
  assert.equal(State.cardSelection, 0);
  for (let i = 0; i < 4; i++) runIslandKey(host, { kind: "list", delta: 1 });
  assert.equal(State.cardSelection, 2);
  runIslandKey(host, { kind: "list", delta: -1 });
  assert.equal(State.cardSelection, 1);
  runIslandKey(host, { kind: "openSelection" });
  assert.deepEqual(did, ["view:openSelection"]);

  // Starting from nothing, ↑ picks the last row.
  State.cardSelection = null;
  runIslandKey(host, { kind: "list", delta: -1 });
  assert.equal(State.cardSelection, 2);

  // Another view is on screen: the overview's list isn't walked.
  State.view = "prompt";
  runIslandKey(host, { kind: "list", delta: -1 });
  assert.equal(State.cardSelection, 2);
  State.view = "overview";

  // Another pill drops the highlight, as cyclePill / switchToPill do.
  runIslandKey(host, { kind: "pill", number: 1 });
  assert.equal(State.cardSelection, null);

  did = [];
  runIslandKey(host, { kind: "diff" });
  assert.deepEqual(did, ["view:toggleDiff"]);
});

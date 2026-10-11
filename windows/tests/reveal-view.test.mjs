// The live-edit reveal in the views: the diff card (src/views/diff.ts) and the
// code view's editor rows (src/views/session.ts), on a fake DOM with a frame
// clock the test turns by hand.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import "./tauri.mjs";

installFakeDom();
globalThis.addEventListener = () => {};

// A frame clock that only moves when the test says so.
const frames = new Map();
let nextFrame = 1;
let clock = 0;
globalThis.requestAnimationFrame = (fn) => {
  frames.set(nextFrame, fn);
  return nextFrame++;
};
globalThis.cancelAnimationFrame = (id) => frames.delete(id);
/** Moves time on in 16 ms frames. */
function advance(ms) {
  for (let spent = 0; spent < ms; spent += 16) {
    clock += 16;
    const due = [...frames.values()];
    frames.clear();
    for (const fn of due) fn(clock);
  }
}

const { buildDiffCard } = await import("../src/views/diff.ts");
const { fromEdit } = await import("../src/core/diff.ts");
const { buildCodeView, codeFor, dropCode, toolStarted } = await import("../src/views/session.ts");
const { DEFAULT_SETTINGS, State } = await import("../src/core/state.ts");
const { REVEAL_CARET, REVEAL_MAX_LINES } = await import("../src/core/reveal.ts");

const CLAUDE = "integration_claude";
const ROOT = "/home/alice/shop";
const SRC = { sessionId: "s1", cwd: ROOT, project: "shop", remote: false };
const hooks = (extra = {}) => ({ dismiss() {}, open() {}, ...extra });

const DIFF = fromEdit("const a = 1;\nconst b = 2;\n", "const a = 1;\nconst total = sum(items);\nreturn total;\n", `${ROOT}/src/cart.ts`);
const rowsOf = (card) => card.find(".diff-line");
/** What a row is set to: nothing at all once it is plain. */
const opacities = (els) => els.map((r) => r.style.opacity || "");

beforeEach(() => {
  frames.clear();
  delete globalThis.matchMedia;
});

afterEach(() => {
  delete globalThis.matchMedia;
});

// ── Diff card ─────────────────────────────────────────────────────────────────

test("a live card enters with a slide, and starts with its lines hidden", () => {
  const card = buildDiffCard(DIFF, hooks({ live: true }));
  assert.ok(card.classList.contains("diff-enter"));
  assert.ok(!card.classList.contains("diff-swap"));
  const rows = rowsOf(card);
  assert.equal(rows.length, 4);
  assert.deepEqual(opacities(rows), ["0", "0", "0", "0"]);
  assert.equal(frames.size, 1);
});

test("a live card replacing a live card cross-fades instead", () => {
  const card = buildDiffCard(DIFF, hooks({ live: true, swap: true }));
  assert.ok(card.classList.contains("diff-swap"));
  assert.ok(!card.classList.contains("diff-enter"));
});

test("a diff opened by hand is instant: no entrance, no hidden lines, no frames", () => {
  const card = buildDiffCard(DIFF, hooks());
  assert.ok(!card.classList.contains("diff-enter"));
  assert.ok(!card.classList.contains("diff-swap"));
  assert.deepEqual(opacities(rowsOf(card)), ["", "", "", ""]);
  assert.equal(frames.size, 0);
});

test("lines come in file order, added ones typed with a caret", () => {
  const card = buildDiffCard(DIFF, hooks({ live: true }));
  const [ctx, del, add1, add2] = rowsOf(card);
  const text = (row) => row.find(".txt")[0];

  advance(48);
  assert.notEqual(ctx.style.opacity, "0");
  assert.equal(text(add1).textContent, "");

  // Context 40 ms, removed 40 ms: the first added line starts at 80 ms.
  advance(160);
  assert.equal(del.style.opacity, "1");
  const typed = text(add1).textContent;
  assert.ok(typed.endsWith(REVEAL_CARET), typed);
  const letters = typed.slice(0, -1);
  assert.ok(letters.length > 0 && letters.length < "const total = sum(items);".length);
  assert.ok("const total = sum(items);".startsWith(letters));
  assert.equal(text(add2).textContent, "");

  advance(2000);
  assert.equal(text(add1).textContent, "const total = sum(items);");
  assert.equal(text(add2).textContent, "return total;");
  assert.ok(!card.find(".reveal-caret").length);
  assert.deepEqual(opacities(rowsOf(card)), ["", "", "", ""]);
});

test("nothing is scheduled once the reveal is done", () => {
  buildDiffCard(DIFF, hooks({ live: true }));
  assert.equal(frames.size, 1);
  advance(2000);
  assert.equal(frames.size, 0);
  advance(500);
  assert.equal(frames.size, 0);
});

test("a card that left the page stops asking for frames", () => {
  const card = buildDiffCard(DIFF, hooks({ live: true }));
  advance(32);
  assert.equal(frames.size, 1);
  for (const row of rowsOf(card)) row.isConnected = false;
  advance(32);
  assert.equal(frames.size, 0);
});

test("more than 60 lines are shown at once", () => {
  const many = fromEdit("", Array.from({ length: REVEAL_MAX_LINES + 1 }, (_, i) => `line ${i}`).join("\n") + "\n", "/p/a.ts");
  // The engine caps what it keeps: use what it gave, topped up to the limit under test.
  const lines = many.hunks.flatMap((h) => h.lines);
  const big = { ...many, hunks: [{ ...many.hunks[0], lines: [...lines, ...lines].slice(0, REVEAL_MAX_LINES + 1) }] };
  const card = buildDiffCard(big, hooks({ live: true }));
  assert.equal(rowsOf(card).length, REVEAL_MAX_LINES + 1);
  assert.equal(frames.size, 0);
  assert.ok(rowsOf(card).every((r) => !r.style.opacity));
});

test("exactly 60 lines are still revealed", () => {
  const body = Array.from({ length: REVEAL_MAX_LINES }, (_, i) => `line ${i}`).join("\n") + "\n";
  const card = buildDiffCard(fromEdit("", body, "/p/a.ts"), hooks({ live: true }));
  assert.equal(rowsOf(card).length, REVEAL_MAX_LINES);
  assert.equal(frames.size, 1);
});

test("prefers-reduced-motion shows everything at once", () => {
  globalThis.matchMedia = (q) => ({ matches: q.includes("prefers-reduced-motion") });
  const card = buildDiffCard(DIFF, hooks({ live: true }));
  assert.equal(frames.size, 0);
  assert.ok(rowsOf(card).every((r) => !r.style.opacity));
  assert.equal(rowsOf(card)[2].find(".txt")[0].textContent, "const total = sum(items);");
});

test("file text goes in as text, never as markup", () => {
  const evil = fromEdit("", "<img src=x onerror=alert(1)>\n", "/p/a.html");
  const card = buildDiffCard(evil, hooks({ live: true }));
  advance(2000);
  assert.equal(rowsOf(card)[0].find(".txt")[0].textContent, "<img src=x onerror=alert(1)>");
  assert.equal(card.find("IMG").length, 0);
});

// ── Code view ─────────────────────────────────────────────────────────────────

const EDIT = {
  file_path: `${ROOT}/src/cart.ts`,
  old_string: "const total = 0;",
  new_string: "const total = sum(items);\nreturn total;",
};
const SNIPPET = { start: 9, lines: ["import { sum } from './sum';", "", "const total = sum(items);", "return total;", "}"], at: 2, len: 2 };

function setup({ live = true } = {}) {
  mock.timers.enable({ apis: ["setTimeout"] });
  State.tasks = [];
  State.focusId = null;
  State.mode = "expanded";
  State.view = "code";
  State.settings = { ...DEFAULT_SETTINGS };
  State.liveDiff = null;
  State.loadIntegrationTasks();
  dropCode(CLAUDE);
  State.focusId = CLAUDE;
  if (live) State.liveDiff = { pillId: CLAUDE, diffId: 1 };
  const view = buildCodeView({ setView() {} });
  return view;
}

// The edit has landed and the lines around it were looked for: its rows show.
const edit = (extra = {}) => {
  toolStarted(CLAUDE, SRC, "Edit", { ...EDIT, ...extra });
  codeFor(CLAUDE).edit.pending = false;
};
const edRows = (view) => view.el.find(".ed-row");
const edText = (row) => row.find(".ed-text")[0].textContent;

test("the code view's rows are revealed while following live", () => {
  const view = setup();
  edit();
  view.sync();
  const rows = edRows(view);
  assert.equal(rows.length, 3); // removed line, two added
  assert.deepEqual(rows.map((r) => r.style.opacity || ""), ["0", "0", "0"]);
  assert.equal(frames.size, 1);

  // Rows fade in where they stand: nothing slides, so nothing bobs.
  advance(60);
  assert.ok(rows.some((r) => r.style.opacity && r.style.opacity !== "0"));
  assert.ok(rows.every((r) => !r.style.transform));

  advance(2000);
  assert.deepEqual(rows.map(edText), ["const total = 0;", "const total = sum(items);", "return total;"]);
  assert.deepEqual(rows.map((r) => r.style.opacity || ""), ["", "", ""]);
  assert.equal(frames.size, 0);
  mock.timers.reset();
});

test("an edit shown by hand (not followed) is instant", () => {
  const view = setup({ live: false });
  edit();
  view.sync();
  assert.equal(frames.size, 0);
  assert.deepEqual(edRows(view).map((r) => r.style.opacity || ""), ["", "", ""]);
  mock.timers.reset();
});

test("an edit is revealed once, with the lines around it already in place", () => {
  const view = setup();
  toolStarted(CLAUDE, SRC, "Edit", EDIT);
  view.sync();
  assert.equal(edRows(view).length, 0);
  assert.equal(frames.size, 0);

  const d = codeFor(CLAUDE);
  d.edit.snippet = SNIPPET;
  d.edit.pending = false;
  view.sync();
  const rows = edRows(view);
  const kinds = rows.map((r) => r.className.replace("ed-row ", ""));
  assert.deepEqual(kinds, ["ctx", "ctx", "del", "add", "add", "ctx"]);
  assert.deepEqual(rows.map((r) => r.style.opacity || ""), ["0", "0", "0", "0", "0", "0"]);

  advance(2000);
  assert.deepEqual(rows.map((r) => r.style.opacity || ""), ["", "", "", "", "", ""]);
  assert.equal(frames.size, 0);
  mock.timers.reset();
});

test("another edit restarts the reveal", () => {
  const view = setup();
  edit();
  view.sync();
  advance(2000);
  assert.equal(frames.size, 0);

  edit({ new_string: "return 0;" });
  view.sync();
  assert.deepEqual(edRows(view).map((r) => r.style.opacity || ""), ["0", "0"]);
  assert.equal(frames.size, 1);
  advance(2000);
  assert.equal(frames.size, 0);
  mock.timers.reset();
});

test("a command's output arriving after the reveal does not replay it", () => {
  const view = setup();
  edit();
  view.sync();
  advance(2000);
  toolStarted(CLAUDE, SRC, "Bash", { command: "npm test" });
  view.sync();
  assert.equal(frames.size, 0);
  assert.deepEqual(edRows(view).map((r) => r.style.opacity || ""), ["", "", ""]);
  mock.timers.reset();
});

test("leaving the live session stops the reveal", () => {
  const view = setup();
  edit();
  view.sync();
  assert.equal(frames.size, 1);
  State.focusId = null;
  State.tasks = [];
  view.sync();
  assert.equal(frames.size, 0);
  mock.timers.reset();
});

// ── Overview ──────────────────────────────────────────────────────────────────

test("the overview opens a followed edit with the entrance, the next one cross-fades", async () => {
  const { buildViews } = await import("../src/views/views.ts");
  const views = buildViews({ setView() {}, blip() {} }, () => {});
  const overview = views.get("overview");
  setup({ live: false });
  State.view = "overview";
  for (const id of [...State.sessionDiffs.keys()]) State.clearSessionDiffs(id);

  const first = State.appendSessionDiff(CLAUDE, DIFF);
  State.liveDiff = { pillId: CLAUDE, diffId: first };
  overview.sync();
  let card = overview.el.find(".diff-card")[0];
  assert.ok(card.classList.contains("diff-enter"));

  const second = State.appendSessionDiff(CLAUDE, fromEdit("a\n", "b\n", `${ROOT}/src/b.ts`));
  State.liveDiff = { pillId: CLAUDE, diffId: second };
  overview.sync();
  card = overview.el.find(".diff-card")[0];
  assert.ok(card.classList.contains("diff-swap"));
  assert.ok(!card.classList.contains("diff-enter"));

  advance(2000);
  assert.equal(frames.size, 0);
  for (const id of [...State.sessionDiffs.keys()]) State.clearSessionDiffs(id);
  State.liveDiff = null;
  mock.timers.runAll();
  mock.timers.reset();
});

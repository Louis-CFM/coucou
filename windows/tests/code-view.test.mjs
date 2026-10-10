// The code view (src/views/session.ts): what a Claude Code session edits and
// runs, fed by the hooks (src/island/hooks.ts) through the real bridge, and
// drawn on a fake DOM that refuses innerHTML.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { calls, emit, internals, sent } from "./tauri.mjs";

installFakeDom();
// The overview listens for Escape on the window.
globalThis.addEventListener = () => {};
const { buildViews } = await import("../src/views/views.ts");
const { registerHookHandlers } = await import("../src/island/hooks.ts");
const { DEFAULT_SETTINGS, State } = await import("../src/core/state.ts");
const session = await import("../src/views/session.ts");
const { buildCodeView, codeFor, codeRowBudget, codeRows, dropCode, fit, hasCode } = session;

const CLAUDE = "integration_claude";
const CURSOR = "agent_cursor";
const ROOT = "/home/alice/shop";

/** What the mocked Rust side answers, by command. */
let answers = {};
const plainInvoke = internals.invoke;
internals.invoke = async (cmd, args) => {
  const result = await plainInvoke(cmd, args);
  if (cmd in answers) return typeof answers[cmd] === "function" ? answers[cmd](args) : answers[cmd];
  return result;
};
const flush = () => new Promise((resolve) => setImmediate(resolve));

let asked;
const island = {
  alert: (view) => asked.push(`alert:${view}`),
  setView: (view) => {
    asked.push(`setView:${view}`);
    State.view = view;
  },
  reveal: () => asked.push("reveal"),
  dropPin: () => asked.push("dropPin"),
};
registerHookHandlers(island);

const hook = (payload) => emit("hook", { session_id: "s1", cwd: ROOT, ...payload });
const prompt = (extra = {}) => hook({ hook_event_name: "UserPromptSubmit", prompt: "fix it", ...extra });
const pre = (tool_name, tool_input, extra = {}) => hook({ hook_event_name: "PreToolUse", tool_name, tool_input, ...extra });
const post = (tool_name, tool_input, extra = {}) => hook({ hook_event_name: "PostToolUse", tool_name, tool_input, ...extra });

const actions = { setView: (v) => asked.push(`action:${v}`) };
function render() {
  const view = buildCodeView(actions);
  view.sync();
  return view.el;
}
const texts = (el, cls) => el.find(cls).map((n) => n.textContent);

const EDIT = {
  file_path: `${ROOT}/src/cart.ts`,
  old_string: "const total = 0;",
  new_string: "const total = sum(items);\nreturn total;",
};
/** What snippet.rs would answer for EDIT: three lines either side. */
const SNIPPET = {
  start: 9,
  lines: ["import { sum } from './sum';", "", "export function cart(items) {", "const total = sum(items);", "return total;", "}", "", "// end"],
  at: 3,
  len: 2,
};

beforeEach(() => {
  // Stop and recorded diffs arm timers of their own: a mock clock lets them go.
  mock.timers.enable({ apis: ["setTimeout"] });
  asked = [];
  calls.length = 0;
  answers = {};
  State.tasks = [];
  State.focusId = null;
  State.mode = "expanded";
  State.view = "overview";
  State.paused = false;
  State.pendingApproval = null;
  State.settings = { ...DEFAULT_SETTINGS };
  State.loadIntegrationTasks();
  for (const id of [CLAUDE, CURSOR, "agent_gemini"]) dropCode(id);
});

afterEach(() => {
  mock.timers.runAll();
  mock.timers.reset();
});

// ── Phases ────────────────────────────────────────────────────────────────────

test("the phases follow the turn: read, edit, bash, then done", () => {
  prompt();
  assert.deepEqual(codeFor(CLAUDE).seen, []);
  pre("Grep", { pattern: "total" });
  assert.equal(codeFor(CLAUDE).current, "read");
  pre("Edit", EDIT);
  pre("Bash", { command: "npm test" });
  const d = codeFor(CLAUDE);
  assert.deepEqual(d.seen, ["read", "edit", "bash"]);
  assert.equal(d.current, "bash");
  assert.equal(d.finished, false);

  State.focusId = CLAUDE;
  let el = render();
  assert.deepEqual(el.find(".phase").map((p) => p.className), [
    "phase done", "phase done", "phase active", "phase todo",
  ]);
  assert.deepEqual(texts(el, ".phase"), ["Read", "Edit", "Bash", "Done"]);

  hook({ hook_event_name: "Stop", last_assistant_message: "Fixed." });
  assert.equal(codeFor(CLAUDE).finished, true);
  el = render();
  assert.deepEqual(el.find(".phase").map((p) => p.className), [
    "phase done", "phase done", "phase done", "phase done",
  ]);

  // A new prompt starts over: the old code goes with the old turn.
  prompt();
  assert.deepEqual(codeFor(CLAUDE).seen, []);
  assert.equal(hasCode(CLAUDE), false);
});

// ── One pill, one session ─────────────────────────────────────────────────────

test("each pill keeps its own code, and a new prompt in one leaves the other", () => {
  pre("Edit", EDIT);
  pre("Bash", { command: "cargo build" }, { session_id: "s2", cwd: "/home/alice/api", term_editor: "cursor" });
  assert.equal(codeFor(CLAUDE).edit.file, "src/cart.ts");
  assert.equal(codeFor(CLAUDE).command, undefined);
  assert.equal(codeFor(CURSOR).command.command, "cargo build");
  assert.equal(codeFor(CURSOR).project, "api");

  prompt({ session_id: "s2", cwd: "/home/alice/api", term_editor: "cursor" });
  assert.equal(hasCode(CURSOR), false);
  assert.equal(hasCode(CLAUDE), true);

  // The view shows the pill in front.
  State.focusId = CURSOR;
  pre("Bash", { command: "cargo test" }, { session_id: "s2", cwd: "/home/alice/api", term_editor: "cursor" });
  let el = render();
  assert.equal(el.querySelector(".code-name").textContent, "api");
  assert.equal(el.querySelector(".term-cmd").textContent, "cargo test");
  State.focusId = CLAUDE;
  el = render();
  assert.equal(el.querySelector(".code-name").textContent, "shop");
  assert.equal(el.querySelector(".term"), null);
});

test("another session in the same pill starts afresh, and SessionEnd forgets it", () => {
  pre("Edit", EDIT);
  pre("Read", { file_path: `/home/alice/api/main.rs` }, { session_id: "s9", cwd: "/home/alice/api" });
  const d = codeFor(CLAUDE);
  assert.equal(d.sessionId, "s9");
  assert.equal(d.root, "/home/alice/api");
  assert.equal(d.edit, undefined);

  State.focusId = CLAUDE;
  pre("Edit", { ...EDIT, file_path: "/home/alice/api/main.rs" }, { session_id: "s9", cwd: "/home/alice/api" });
  State.view = "code";
  hook({ hook_event_name: "SessionEnd", session_id: "s9", cwd: "/home/alice/api" });
  assert.equal(codeFor(CLAUDE), null);
  assert.deepEqual(asked, ["setView:overview"]);
});

test("external agents get no code view", () => {
  pre("Edit", EDIT, { coucou_agent: "gemini" });
  assert.equal(codeFor("agent_gemini"), null);
  assert.equal(hasCode(CLAUDE), false);
});

// ── The editor pane ───────────────────────────────────────────────────────────

test("an edit is shown in place: snippet line numbers, removed red, added green", async () => {
  answers.file_snippet = SNIPPET;
  pre("Edit", EDIT);
  post("Edit", EDIT);
  assert.deepEqual(sent("file_snippet"), [{ cwd: ROOT, path: EDIT.file_path, find: EDIT.new_string, context: 3 }]);
  await flush();

  const rows = codeRows(codeFor(CLAUDE).edit);
  assert.deepEqual(rows.map((r) => `${r.kind}:${r.n ?? "-"}`), [
    "ctx:9", "ctx:10", "ctx:11", "del:-", "add:12", "add:13", "ctx:14", "ctx:15", "ctx:16",
  ]);
  assert.equal(rows[3].text, "const total = 0;");

  // Room for 5: the far context goes first, the change stays.
  assert.deepEqual(fit(rows, 5).map((r) => r.n ?? "-"), [11, "-", 12, 13, 14]);
  // Only changed rows left: the start of the change is kept.
  assert.deepEqual(fit(rows, 2).map((r) => r.kind), ["del", "add"]);
  assert.equal(fit(rows, 11).length, rows.length);

  State.focusId = CLAUDE;
  const el = render();
  assert.equal(el.querySelector(".ed-name").textContent, "cart.ts");
  assert.equal(el.querySelector(".ed-chip").textContent, "TS");
  assert.equal(el.querySelector(".ed-dir").textContent, "src/cart.ts");
  assert.deepEqual(el.find(".ed-row").map((r) => r.className.replace("ed-row ", "")),
    ["ctx", "ctx", "ctx", "del", "add", "add", "ctx", "ctx", "ctx"]);
  assert.deepEqual(texts(el, ".ed-n"), ["9", "10", "11", "", "12", "13", "14", "15", "16"]);
  assert.equal(el.find(".ed-text")[4].textContent, "const total = sum(items);");
});

test("a snippet that answers late, for an edit since replaced, is dropped", async () => {
  const pending = [];
  answers.file_snippet = () => new Promise((resolve) => pending.push(resolve));
  pre("Edit", EDIT);
  post("Edit", EDIT);
  post("Edit", { ...EDIT, new_string: "other" });
  await flush();
  // The first edit's answer arrives after the second edit.
  pending[0](SNIPPET);
  await flush();
  assert.equal(codeFor(CLAUDE).edit.added, "other");
  assert.equal(codeFor(CLAUDE).edit.snippet, undefined);
});

test("a write is numbered from line 1, an edit without a snippet is unnumbered", async () => {
  pre("Write", { file_path: `${ROOT}/notes.md`, content: "# Notes\n\n- one\n" });
  let rows = codeRows(codeFor(CLAUDE).edit);
  assert.deepEqual(rows.map((r) => `${r.kind}:${r.n}`), ["add:1", "add:2", "add:3"]);
  post("Write", { file_path: `${ROOT}/notes.md`, content: "# Notes\n\n- one\n" });
  assert.deepEqual(sent("file_snippet"), [], "a written file is shown from its own text");

  // Rust found nothing (or the file is outside the folder): the edit alone.
  post("Edit", EDIT);
  await flush();
  rows = codeRows(codeFor(CLAUDE).edit);
  assert.deepEqual(rows.map((r) => `${r.kind}:${r.n}`), ["del:null", "add:null", "add:null"]);
});

test("a remote session's edit is still shown, but its file is never read here", async () => {
  answers.file_snippet = SNIPPET;
  const remote = { coucou_remote: "devbox.example", cwd: "/srv/shop" };
  pre("Edit", { ...EDIT, file_path: "/srv/shop/src/cart.ts" }, remote);
  post("Edit", { ...EDIT, file_path: "/srv/shop/src/cart.ts" }, remote);
  await flush();
  assert.deepEqual(sent("file_snippet"), []);
  const d = codeFor(CLAUDE);
  assert.equal(d.remote, true);
  assert.equal(d.edit.file, "src/cart.ts");
  assert.equal(d.edit.snippet, undefined);
  assert.equal(hasCode(CLAUDE), true);
});

// ── The terminal box ──────────────────────────────────────────────────────────

test("a command shows with the last lines it printed, PASS and FAIL as badges", () => {
  pre("Bash", { command: "npm   test\n  --silent" });
  State.focusId = CLAUDE;
  let el = render();
  assert.equal(el.querySelector(".term-cmd").textContent, "npm test --silent");
  assert.equal(el.querySelector(".term-run").textContent, "…");
  assert.equal(el.querySelector(".ed-name").textContent, "bash");

  post("Bash", { command: "npm test" }, {
    tool_tail: ["PASS tests/cart.test.ts", "  ✓ adds up (3 ms)", "<b>Tests:</b> 1 passed"],
  });
  assert.equal(codeFor(CLAUDE).command.status, "ok");
  el = render();
  assert.equal(el.querySelector(".term-run"), null);
  assert.equal(el.querySelector(".badge.pass").textContent, "PASS");
  const lines = el.find(".term-line");
  assert.deepEqual(lines.map((l) => l.textContent), [
    "$npm test --silent", "PASStests/cart.test.ts", "✓ adds up (3 ms)", "<b>Tests:</b> 1 passed",
  ]);
  assert.ok(lines[2].classList.contains("good"));
  // Text from the output is text: no element was made of it.
  assert.equal(lines[3].children.length, 0);
});

test("a failed command shows its error when it printed nothing, and the code makes room", () => {
  pre("Bash", { command: "cargo build" });
  hook({ hook_event_name: "PostToolUseFailure", tool_name: "Bash", tool_input: { command: "cargo build" }, error: "exit status 101\nmore" });
  const d = codeFor(CLAUDE);
  assert.equal(d.command.status, "failed");
  assert.deepEqual(d.command.tail, ["exit status 101"]);
  assert.equal(codeRowBudget(d), 8);

  post("Bash", { command: "false" }, { tool_tail: "not a list" });
  pre("Bash", { command: "false" });
  hook({ hook_event_name: "PostToolUseFailure", tool_name: "Bash", tool_input: { command: "false" } });
  State.focusId = CLAUDE;
  const el = render();
  assert.equal(el.querySelector(".term-line.bad").textContent, "Failed");
  assert.equal(el.querySelector(".badge"), null);
  assert.equal(codeRowBudget(codeFor(CLAUDE)), 9);
});

test("FAIL lines get a red badge", () => {
  pre("Bash", { command: "npm test" });
  post("Bash", { command: "npm test" }, { tool_tail: ["FAIL tests/cart.test.ts"] });
  State.focusId = CLAUDE;
  const el = render();
  assert.equal(el.querySelector(".badge.fail").textContent, "FAIL");
});

// ── Opening and leaving ───────────────────────────────────────────────────────

test("the back button goes to the overview, and nothing opens the view by itself", () => {
  pre("Edit", EDIT);
  post("Edit", EDIT);
  hook({ hook_event_name: "Stop" });
  assert.ok(!asked.some((a) => a.includes("code")));
  State.focusId = CLAUDE;
  const el = render();
  el.querySelector(".code-back").fire("click");
  assert.deepEqual(asked.filter((a) => a.startsWith("action:")), ["action:overview"]);
});

test("a new prompt in the pill on screen leaves the code view, another pill's does not", () => {
  pre("Edit", EDIT);
  pre("Bash", { command: "ls" }, { session_id: "s2", term_editor: "cursor" });
  State.focusId = CLAUDE;
  State.view = "code";
  prompt({ session_id: "s2", term_editor: "cursor" });
  assert.equal(State.view, "code");
  prompt();
  assert.equal(State.view, "overview");
});

test("the overview's left card opens the code view on a click, once there is code", () => {
  const opened = [];
  const views = buildViews({ setView: (v) => opened.push(v), blip() {} }, () => {});
  const overview = views.get("overview");
  assert.ok(views.has("code"));

  prompt();
  State.focusId = CLAUDE;
  overview.sync();
  const [left] = overview.el.find(".card");
  assert.equal(left.classList.contains("expandable"), false);
  left.fire("click");
  assert.deepEqual(opened, []);

  pre("Bash", { command: "npm test" });
  overview.sync();
  assert.equal(left.classList.contains("expandable"), true);
  left.fire("click");
  assert.deepEqual(opened, ["code"]);
});

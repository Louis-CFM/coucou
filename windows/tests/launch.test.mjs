// A new Claude Code session from the island and a file dropped on a session
// (src/core/launch.ts, src/views/launch.ts, src/views/session-drop.ts): the
// projects remembered from the hooks, the launch card through the real
// bridge, and which session a dragged file is over.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { calls, internals, sent } from "./tauri.mjs";

installFakeDom();

/** The webview's storage, so the launcher's memory can be watched. */
const storage = new Map();
globalThis.localStorage = {
  getItem: (k) => (storage.has(k) ? storage.get(k) : null),
  setItem: (k, v) => storage.set(k, String(v)),
};

const {
  DROP_LIST, DROP_TEXT_RIGHT_WITH_LIST, Launch, Launcher, MAX_PROJECTS, dropTargetAt, dropTargets, dropTargetsLayout,
  isRootOrHome, normalizeFolder, projectName, rememberProject,
} = await import("../src/core/launch.ts");
const { buildLaunch } = await import("../src/views/launch.ts");
const { buildSessionDropList } = await import("../src/views/session-drop.ts");
const { State } = await import("../src/core/state.ts");
// The drop card's geometry (USC in src/upload/sequence.ts, which Node can't
// load as it is: it uses TypeScript parameter properties).
const USC = { CARD_X: 10, CARD_Y: 42, CARD_W: 620, CARD_H: 124, TEXT_X: 196, REST_X: 140, REST_Y: 104 };

let answers;
const plainInvoke = internals.invoke;
internals.invoke = async (cmd, args) => {
  const result = await plainInvoke(cmd, args);
  if (cmd in answers) return typeof answers[cmd] === "function" ? answers[cmd](args) : answers[cmd];
  return result;
};
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

beforeEach(() => {
  calls.length = 0;
  answers = {};
  storage.clear();
});

// ── Projects ──────────────────────────────────────────────────────────────────

test("a folder loses its trailing separators, a root keeps its own", () => {
  assert.equal(normalizeFolder("/home/me/app/"), "/home/me/app");
  assert.equal(normalizeFolder("C:\\code\\app\\\\"), "C:\\code\\app");
  assert.equal(normalizeFolder("/"), "/");
  assert.equal(normalizeFolder("C:\\"), "C:\\");
});

test("roots and home folders are never projects", () => {
  for (const p of ["/", "C:\\", "D:", "/home/me", "/home/me/", "/root", "/Users/me", "C:\\Users\\me", "c:\\users\\Me\\"]) {
    assert.ok(isRootOrHome(p), p);
  }
  for (const p of ["/home/me/app", "C:\\Users\\me\\code", "/srv/site", "D:\\work"]) assert.ok(!isRootOrHome(p), p);
});

test("projects: most recent first, no duplicates, ten at most, home and / left out", () => {
  let list = rememberProject("/home/me/a/", [], false);
  list = rememberProject("/home/me/b", list, false);
  list = rememberProject("/home/me/a", list, false);
  assert.deepEqual(list, ["/home/me/a", "/home/me/b"]);
  assert.deepEqual(rememberProject("/home/me", list, false), list);
  assert.deepEqual(rememberProject("/", list, false), list);
  assert.deepEqual(rememberProject("relative/dir", list, false), list);
  assert.deepEqual(rememberProject("", list, false), list);
  let many = [];
  for (let i = 0; i < 15; i++) many = rememberProject(`/p/${i}`, many, false);
  assert.equal(many.length, MAX_PROJECTS);
  assert.equal(many[0], "/p/14");
});

test("on Windows the same folder in another letter case is the same project", () => {
  let list = rememberProject("C:\\Code\\App", [], true);
  list = rememberProject("D:\\other", list, true);
  list = rememberProject("c:\\code\\app\\", list, true);
  assert.deepEqual(list, ["c:\\code\\app", "D:\\other"]);
  // Linux paths are case-sensitive.
  assert.deepEqual(rememberProject("/srv/App", ["/srv/app"], false), ["/srv/App", "/srv/app"]);
});

test("a project is shown by its last folder name", () => {
  assert.equal(projectName("/home/me/my-app/"), "my-app");
  assert.equal(projectName("C:\\code\\Coucou"), "Coucou");
  assert.equal(projectName("/"), "/");
});

test("the launcher keeps its projects and the chosen folder in the webview's storage", () => {
  const a = new Launcher(false);
  assert.deepEqual(a.projects, []);
  assert.equal(a.folder, null);
  a.remember("/srv/one");
  assert.equal(a.folder, "/srv/one", "the first project becomes the folder");
  a.remember("/srv/two");
  assert.equal(a.folder, "/srv/one", "a later session doesn't move it");
  a.choose("/opt/picked/");
  assert.equal(a.folder, "/opt/picked");
  assert.deepEqual(a.projects, ["/opt/picked", "/srv/two", "/srv/one"], "a picked folder joins the list");

  const b = new Launcher(false);
  assert.deepEqual(b.projects, a.projects);
  assert.equal(b.folder, "/opt/picked");

  storage.set("coucou.launch.projects", "{not json");
  storage.delete("coucou.launch.folder");
  const c = new Launcher(false);
  assert.deepEqual(c.projects, []);
  assert.equal(c.folder, null);
});

test("storage that refuses leaves an empty launcher, not an error", () => {
  const saved = globalThis.localStorage;
  globalThis.localStorage = { getItem() { throw new Error("denied"); }, setItem() { throw new Error("denied"); } };
  try {
    const l = new Launcher(true);
    l.remember("C:\\code\\x");
    assert.deepEqual(l.projects, ["C:\\code\\x"]);
  } finally {
    globalThis.localStorage = saved;
  }
});

// ── Launch card ───────────────────────────────────────────────────────────────

function card() {
  const did = { launched: 0, hold: [], keyboard: [] };
  const actions = {
    blip() {},
    holdOpen: (on) => did.hold.push(on),
    keyboard: (on) => did.keyboard.push(on),
    launched: () => did.launched++,
  };
  State.view = "launch";
  const view = buildLaunch(actions);
  view.el.querySelector(".chat-input").value = ""; // a real field starts empty
  view.sync();
  return { view, did, $: (cls) => view.el.querySelector(cls) };
}

test("Enter starts Claude Code in the chosen folder with what was typed, then the island folds", async () => {
  Launch.projects = ["/srv/site", "/srv/api"];
  Launch.folder = "/srv/site";
  answers.launch_session = true;
  const { view, did, $ } = card();
  assert.equal($(".launch-project-name").textContent, "site");
  const input = $(".chat-input");
  input.value = `fix the "login" bug; rm -rf /`;
  input.fire("input");
  assert.deepEqual(did.hold, [true], "typing keeps the island open");
  // The fake DOM's fire() has no key: the listeners get one by hand.
  const ev = { key: "Enter", preventDefault() {}, stopPropagation() {} };
  for (const fn of input.listeners.get("keydown")) fn(ev);
  await flush();
  assert.deepEqual(sent("launch_session"), [{ folder: "/srv/site", prompt: `fix the "login" bug; rm -rf /` }]);
  assert.equal(did.launched, 1);
  assert.equal(input.value, "");
  view.sync();
  assert.ok(!$(".launch-hint").classList.contains("is-failed"));
});

test("a terminal that couldn't open says so and keeps the words", async () => {
  Launch.folder = "/srv/site";
  answers.launch_session = false;
  const { view, did, $ } = card();
  $(".chat-input").value = "add tests";
  $(".launch-send").fire("click");
  await flush();
  assert.equal(did.launched, 0);
  assert.equal($(".chat-input").value, "add tests");
  assert.ok($(".launch-hint").classList.contains("is-failed"));
  assert.equal($(".launch-hint").textContent, "Couldn't open the terminal in this folder.");
  // Opened again later (the island calls focus() each time): a fresh hint.
  view.focus();
  assert.ok(!$(".launch-hint").classList.contains("is-failed"));
});

test("without a project, sending asks for a folder first", async () => {
  Launch.projects = [];
  Launch.folder = null;
  answers.pick_folder = "/home/me/new-app";
  const { $ } = card();
  assert.equal($(".launch-project-name").textContent, "Choose a project");
  assert.ok($(".launch-send").disabled);
  const ev = { key: "Enter", preventDefault() {}, stopPropagation() {} };
  for (const fn of $(".chat-input").listeners.get("keydown")) fn(ev);
  await flush();
  assert.deepEqual(sent("pick_folder"), [{ start: null }]);
  assert.deepEqual(sent("launch_session"), [], "nothing starts until a folder is chosen");
  assert.equal(Launch.folder, "/home/me/new-app");
  assert.equal($(".launch-project-name").textContent, "new-app");
});

test("the project menu lists the projects, then Choose a folder…", async () => {
  Launch.projects = ["/srv/site", "/srv/api"];
  Launch.folder = "/srv/site";
  const { view, $ } = card();
  $(".launch-project").fire("click");
  assert.ok($(".launch-body").classList.contains("choosing"));
  const rows = view.el.find(".picker-model");
  assert.deepEqual(rows.map((r) => r.textContent), ["site", "api", "Choose a folder…"]);
  assert.ok(rows[0].classList.contains("on"));
  rows[1].fire("click");
  assert.equal(Launch.folder, "/srv/api");
  assert.ok(!$(".launch-body").classList.contains("choosing"));
  assert.equal($(".launch-project-name").textContent, "api");

  answers.pick_folder = null; // cancelled
  $(".launch-project").fire("click");
  view.el.find(".picker-model").at(-1).fire("click");
  await flush();
  assert.deepEqual(sent("pick_folder"), [{ start: "/srv/api" }]);
  assert.equal(Launch.folder, "/srv/api");
});

// ── Drop on a session ─────────────────────────────────────────────────────────

const task = (id, sessionId, name = id) => ({
  id, name, color: "#D97757", state: "idle", stepIndex: 0, steps: [], source: "agent", isIntegration: id.startsWith("integration_"),
  sessionId, sessionCwd: sessionId ? `/srv/${name}` : null,
});

test("the sessions offered: pills with a session, not Claude Desktop, three at most", () => {
  const tasks = [
    task("integration_claude", "s1", "site"),
    task("integration_github", null),
    task("agent_claude-desktop", "d1"),
    task("agent_cursor", "s2"),
    task("agent_codex", "s3"),
    task("agent_gemini", "s4"),
  ];
  assert.deepEqual(dropTargets(tasks).map((t) => t.id), ["integration_claude", "agent_cursor", "agent_codex"]);
  assert.deepEqual(dropTargets([task("integration_github", null)]), []);
});

test("the list sits on the right of the drop card, centred, and never over its text", () => {
  for (const n of [1, 2, 3]) {
    const { title, rows } = dropTargetsLayout(n);
    assert.equal(rows.length, n);
    const top = title.y;
    const bottom = rows.at(-1).y + rows.at(-1).h;
    assert.ok(top >= USC.CARD_Y + 4 && bottom <= USC.CARD_Y + USC.CARD_H - 4, `n=${n} inside the card`);
    assert.ok(Math.abs((top + bottom) / 2 - DROP_LIST.centreY) <= 1, `n=${n} centred`);
    for (const r of rows) {
      assert.equal(r.x + r.w, USC.CARD_X + USC.CARD_W - 22, "22 from the card's edge");
      assert.equal(r.w, 150);
    }
  }
  assert.deepEqual(dropTargetsLayout(7).rows.length, 3);
  assert.ok(DROP_TEXT_RIGHT_WITH_LIST < dropTargetsLayout(3).rows[0].x);
  assert.ok(DROP_TEXT_RIGHT_WITH_LIST > USC.TEXT_X + 150, "the drop text keeps room");
});

test("the row under the pointer takes the file; elsewhere on the card, none", () => {
  const { rows } = dropTargetsLayout(3);
  const mid = (r) => [r.x + r.w / 2, r.y + r.h / 2];
  assert.equal(dropTargetAt(...mid(rows[0]), 3), 0);
  assert.equal(dropTargetAt(...mid(rows[2]), 3), 2);
  assert.equal(dropTargetAt(rows[1].x - 3, rows[1].y + 2, 3), 1, "a little slack around a row");
  assert.equal(dropTargetAt(rows[1].x - 10, rows[1].y + 2, 3), null);
  assert.equal(dropTargetAt(USC.REST_X, USC.REST_Y, 3), null, "Mochi's box is the usual drop");
  const two = dropTargetsLayout(2).rows;
  assert.equal(dropTargetAt(two[1].x + 20, two[1].y + two[1].h + 10, 2), null, "no third row with two sessions");
  assert.equal(dropTargetAt(...mid(rows[0]), 0), null);
});

test("the drop card's list shows the sessions and lights the one under the pointer", () => {
  State.tasks = [task("integration_claude", "s1", "site"), task("agent_codex", "s3", "api")];
  State.dropSessionTarget = null;
  const list = buildSessionDropList();
  list.sync(false);
  assert.ok(!list.el.classList.contains("on"));
  list.sync(true);
  assert.ok(list.el.classList.contains("on"));
  const rows = list.el.find(".sd-row");
  assert.deepEqual(rows.map((r) => r.textContent), ["site", "api"]);
  assert.ok(rows.every((r) => !r.classList.contains("over")));
  State.dropSessionTarget = "agent_codex";
  list.sync(true);
  assert.ok(rows[1].classList.contains("over"));
  assert.ok(!rows[0].classList.contains("over"));
  assert.equal(list.el.querySelector(".sd-title").textContent, "Or into a session");

  State.tasks = [task("integration_github", null)];
  list.sync(true);
  assert.ok(!list.el.classList.contains("on"), "no session: no list");
});

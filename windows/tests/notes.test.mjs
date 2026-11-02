// The Notetaker page against a fake bridge.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import ts from "typescript";
import { installFakeDom } from "./fakedom.mjs";
import { calls, internals, sent } from "./tauri.mjs";

const { root } = installFakeDom();
// The page imports the real animated hero, whose parameter property needs a
// TypeScript transform rather than Node's built-in type stripping.
registerHooks({ load(url, context, nextLoad) {
  const loaded = nextLoad(url, context);
  if (!url.endsWith("/src/hub/hero.ts")) return loaded;
  return { ...loaded, format: "module", source: ts.transpileModule(String(loaded.source), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
  }).outputText };
} });
document.addEventListener = () => {};
document.documentElement = { lang: "en" };
document.visibilityState = "hidden";
globalThis.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener() {} };
// In-place editors swap a title or speaker chip for an input.
Object.getPrototypeOf(root()).replaceWith = function (node) {
  const parent = this.parentNode;
  parent.childNodes[parent.childNodes.indexOf(this)] = node;
  node.parentNode = parent;
  this.parentNode = null;
};
Object.getPrototypeOf(root()).removeEventListener = function (type, fn) {
  this.listeners.set(type, (this.listeners.get(type) ?? []).filter(listener => listener !== fn));
};
const press = (input, key) => { for (const fn of input.listeners.get("keydown") ?? []) fn({ key }); };
const { notesPage } = await import("../src/hub/pages/notes.ts");
const flush = () => new Promise(resolve => setTimeout(resolve, 0));
const originalInvoke = internals.invoke;

/** The page with one saved call, selected. */
async function readyPage(t) {
  calls.length = 0;
  t.mock.method(globalThis, "setInterval", () => 1);
  t.mock.method(globalThis, "clearInterval", () => {});
  const note = {
    id: "synthetic", title: "Synthetic call", start: Date.now() - 10_000, end: Date.now(),
    status: "ready", speakers: [], lines: [{ start: 0, speaker: "me", text: "Test" }],
    summary: "", keyPoints: [], todos: [],
  };
  const state = { notes: [note], recording: null, working: [] };
  t.mock.method(internals, "invoke", async (cmd, args) => {
    const fallback = await originalInvoke(cmd, args);
    if (cmd === "notes_state") return structuredClone(state);
    return fallback;
  });
  const page = root();
  const ctx = { hero: () => root(), status: { models: { parakeet: { state: "ready" } } } };
  await notesPage(page, ctx);
  t.after(() => ctx.onLeave());
  return { page, state, detail: () => page.querySelector(".hub-note-detail") };
}

test("a failed delete keeps the call listed with the reason beside the confirmation", async t => {
  const fixture = await readyPage(t);
  const answer = internals.invoke;
  t.mock.method(internals, "invoke", async (cmd, args) => {
    if (cmd === "notes_delete") throw "Could not remove: mic.wav is open in another program";
    return answer(cmd, args);
  });
  const detail = fixture.detail();
  detail.find("button").find(b => b.getAttribute("aria-label") === "Delete").fire("click");
  detail.find("button").find(b => b.textContent === "Delete").fire("click");
  await flush();
  assert.match(detail.textContent, /Could not remove: mic\.wav is open in another program/);
  assert.match(detail.textContent, /Delete this call and its notes\?/);
  assert.match(fixture.page.querySelector(".hub-notes-list").textContent, /Synthetic call/);
});

test("Escape keeps the old title even though removing the editor blurs it", async t => {
  const fixture = await readyPage(t);
  const detail = fixture.detail();
  detail.find("h2")[0].fire("click");
  const input = detail.find("input")[0];
  input.value = "Draft title";
  press(input, "Escape");
  input.fire("blur"); // WebView2 fires blur on an input removed from the page
  await flush();
  assert.equal(sent("notes_rename").length, 0);
  assert.equal(detail.find("h2")[0].textContent, "Synthetic call");
});

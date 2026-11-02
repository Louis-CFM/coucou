// The Notetaker page against a fake bridge: what it shows when a native command fails.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import ts from "typescript";
import { installFakeDom } from "./fakedom.mjs";
import { internals } from "./tauri.mjs";

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
const { notesPage } = await import("../src/hub/pages/notes.ts");
const flush = () => new Promise(resolve => setTimeout(resolve, 0));
const originalInvoke = internals.invoke;

/** The page with one saved call, selected. */
async function readyPage(t) {
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

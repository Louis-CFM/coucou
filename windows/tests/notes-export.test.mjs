import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import ts from "typescript";
import { installFakeDom } from "./fakedom.mjs";
import { calls, emit, internals, sent } from "./tauri.mjs";
import { FlowBridge } from "../src/core/flow.ts";

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
Object.getPrototypeOf(root()).prepend = function (...nodes) {
  for (const node of nodes) node.parentNode = this;
  this.childNodes.unshift(...nodes);
};
const { notesPage } = await import("../src/hub/pages/notes.ts");
const flush = () => new Promise(resolve => setTimeout(resolve, 0));
const originalInvoke = internals.invoke;

async function recordingPage(t) {
  t.mock.method(globalThis, "setInterval", () => 1);
  t.mock.method(globalThis, "clearInterval", () => {});
  const note = { id: "synthetic", title: "Synthetic call", start: Date.now() - 10000,
    status: "ready", speakers: [], lines: [{ start: 0, speaker: "me", text: "Test" }],
    summary: "", keyPoints: [], todos: [] };
  t.mock.method(internals, "invoke", async (cmd, args) => {
    if (cmd === "notes_state") return { notes: [note], recording: null, working: [] };
    return originalInvoke(cmd, args);
  });
  const page = root();
  const ctx = { hero: () => root(), status: { models: { parakeet: { state: "ready" } } } };
  await notesPage(page, ctx);
  t.after(() => ctx.onLeave());
  return { page };
}

async function exportPage(t) {
  const fixture = await recordingPage(t);
  return {
    ...fixture,
    exportButton: () => fixture.page.find("button").find(b => b.textContent === "Export as Markdown…"),
    detail: () => fixture.page.querySelector(".hub-note-detail"),
  };
}

test("a pending export opens only one dialog and cancellation reports no saved file", async t => {
  const fixture = await exportPage(t);
  let complete, requests = 0;
  t.mock.method(FlowBridge, "exportNote", () => {
    requests++;
    return new Promise(resolve => { complete = resolve; });
  });
  const button = fixture.exportButton();
  button.fire("click");
  assert.equal(button.disabled, true);
  button.fire("click");
  assert.equal(requests, 1);
  complete(null);
  await flush();
  assert.equal(fixture.exportButton().disabled, false);
  assert.doesNotMatch(fixture.detail().textContent, /Saved as/);
});

test("an export failure is visible and a successful retry reports the selected path", async t => {
  const fixture = await exportPage(t);
  let fail = true;
  t.mock.method(FlowBridge, "exportNote", async () => {
    if (fail) throw new Error("Destination is not writable");
    return "C:\\chosen\\Synthetic call.md";
  });
  fixture.exportButton().fire("click");
  await flush();
  assert.match(fixture.detail().textContent, /Destination is not writable/);
  assert.equal(fixture.exportButton().disabled, false);
  fail = false;
  fixture.exportButton().fire("click");
  await flush();
  assert.doesNotMatch(fixture.detail().textContent, /Destination is not writable/);
  assert.match(fixture.detail().textContent, /Saved as C:\\chosen\\Synthetic call\.md/);
});

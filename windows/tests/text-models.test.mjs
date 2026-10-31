import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import ts from "typescript";
import { installFakeDom } from "./fakedom.mjs";
import { internals } from "./tauri.mjs";

const { root } = installFakeDom();
registerHooks({ load(url, context, nextLoad) {
  const loaded = nextLoad(url, context);
  if (!url.endsWith("/src/hub/hero.ts")) return loaded;
  return { ...loaded, format: "module", source: ts.transpileModule(String(loaded.source), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
  }).outputText };
} });
document.addEventListener = () => {};
window.addEventListener = () => {};
window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };
document.documentElement = { lang: "en" };
document.visibilityState = "hidden";
const proto = Object.getPrototypeOf(root());
proto.prepend = function (...nodes) { this.replaceChildren(...nodes, ...this.childNodes); };
const { flowSettingsPage } = await import("../src/hub/pages/flowsettings.ts");
const { notesPage } = await import("../src/hub/pages/notes.ts");
const originalInvoke = internals.invoke;

function context() {
  const status = { prefs: { enabled: false, key: "right_ctrl", edge: "bottom", mic: "", keepDays: 30, summaryEngine: "claude" },
    models: { parakeet: { state: "ready" }, downloadMb: 700 }, mics: [], keys: "ok", platform: "windows" };
  return { hero: root, status, refresh: async () => status, setPrefs: async change => change(status.prefs) };
}

test("the summary picker saves each local provider without changing dictation preferences", async t => {
  const ctx = context();
  const page = root();
  await flowSettingsPage(page, ctx);
  t.after(() => ctx.onLeave?.());
  const picker = page.find("select").find(el => el.find("option").some(option => option.getAttribute("value") === "ollama"));
  assert.ok(picker);
  assert.deepEqual(picker.find("option").map(option => option.getAttribute("value")), ["claude", "ollama", "lmstudio", "custom", "off"]);
  for (const provider of ["ollama", "lmstudio", "custom", "off", "claude"]) {
    picker.value = provider;
    picker.fire("change");
    assert.equal(ctx.status.prefs.summaryEngine, provider);
    assert.equal(ctx.status.prefs.key, "right_ctrl");
    assert.equal(ctx.status.prefs.keepDays, 30);
  }
});

test("a provider error stays visible beside a retained summary and allows retry", async t => {
  t.mock.method(globalThis, "setInterval", () => 1);
  t.mock.method(globalThis, "clearInterval", () => {});
  const note = { id: "fixture", title: "Synthetic call", titleEdited: false, start: 1000000, end: 1060000,
    status: "ready", speakers: [], lines: [{ id: "line", speaker: "me", start: 0, end: 2, text: "Synthetic transcript" }], summary: "The existing summary", keyPoints: [], todos: [],
    error: "The model server timed out.", startLocal: "2026-10-30" };
  const requested = [];
  t.mock.method(internals, "invoke", async (cmd, args) => {
    if (cmd === "notes_state") return { notes: [note], working: [], recording: null };
    if (cmd === "notes_summarize") { requested.push(args.id); return; }
    return originalInvoke(cmd, args);
  });
  const ctx = context();
  const page = root();
  await notesPage(page, ctx);
  t.after(() => ctx.onLeave?.());
  assert.match(page.textContent, /The existing summary/);
  assert.match(page.querySelector(".hub-warn").textContent, /timed out/);
  page.find("button").find(button => button.textContent === "Write the summary again").fire("click");
  assert.deepEqual(requested, ["fixture"]);
});

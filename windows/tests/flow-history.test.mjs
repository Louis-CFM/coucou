import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import ts from "typescript";
import { installFakeDom } from "./fakedom.mjs";
import { calls, emit, internals, sent } from "./tauri.mjs";

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
proto.disabled = false;
proto.prepend = function (...nodes) {
  const before = [...this.childNodes];
  this.replaceChildren(...nodes, ...before);
};
proto.querySelectorAll = function (selector) {
  const tags = selector.split(",").map(tag => tag.trim().toUpperCase());
  return [...this.walk()].filter(el => tags.includes(el.tagName));
};
const querySelector = proto.querySelector;
proto.querySelector = function (selector) {
  return selector.startsWith(".") ? querySelector.call(this, selector) : this.find(selector)[0] ?? null;
};
const { dictationPage } = await import("../src/hub/pages/dictation.ts");
const { flowSettingsPage } = await import("../src/hub/pages/flowsettings.ts");
const flush = () => new Promise(resolve => setTimeout(resolve, 0));
const originalInvoke = internals.invoke;
const button = (page, name) => page.find("button").find(b => b.textContent === name || b.getAttribute("aria-label") === name);
const entry = (id, text) => ({ id, text, date: Date.now(), app: null, words: 2, seconds: 1 });

async function fixture(t, render) {
  calls.length = 0;
  let write = async () => {};
  t.mock.method(internals, "invoke", async (cmd, args) => {
    const fallback = await originalInvoke(cmd, args);
    if (cmd === "flow_history") return [entry("first", "Saved dictation")];
    if (cmd === "flow_delete" || cmd === "flow_clear") return write(cmd, args);
    return fallback;
  });
  const page = root();
  const status = {
    prefs: { enabled: true, key: "right_ctrl", keepDays: 30, mic: "" },
    models: { parakeet: { state: "ready" }, downloadMb: 700 },
    mics: [], keys: "ok", platform: "windows",
  };
  const ctx = { hero: root, status, refresh: async () => status, setPrefs: async change => change(status.prefs) };
  await render(page, ctx);
  t.after(() => ctx.onLeave?.());
  await flush();
  return { page, write: fn => { write = fn; } };
}

test("a failed history deletion retains the entry and supports retry", async t => {
  const f = await fixture(t, dictationPage);
  f.write(async () => { throw new Error("History file is locked"); });
  button(f.page, "Delete").fire("click");
  await flush();
  assert.match(f.page.textContent, /Saved dictation/);
  assert.match(f.page.querySelector(".hub-warn").textContent, /locked/);
  f.write(async () => {});
  button(f.page, "Delete").fire("click");
  await flush();
  assert.doesNotMatch(f.page.textContent, /Saved dictation/);
  assert.equal(f.page.querySelector(".hub-warn").hidden, true);
});

test("pending deletion waits for disk, prevents duplicates and preserves incoming dictations", async t => {
  const f = await fixture(t, dictationPage);
  let finish;
  f.write(() => new Promise(resolve => { finish = resolve; }));
  const remove = button(f.page, "Delete");
  remove.fire("click");
  await flush();
  assert.equal(remove.disabled, true);
  assert.match(f.page.textContent, /Saved dictation/);
  remove.fire("click");
  emit("flow-history", entry("second", "New dictation"));
  button(f.page, "Delete").fire("click");
  await flush();
  assert.equal(sent("flow_delete").length, 1);
  finish();
  await flush();
  assert.doesNotMatch(f.page.textContent, /Saved dictation/);
  assert.match(f.page.textContent, /New dictation/);
});

test("erasing history reports disk failures and blocks duplicate requests until retry", async t => {
  const f = await fixture(t, flowSettingsPage);
  let fail;
  f.write(() => new Promise((_, reject) => { fail = reject; }));
  const erase = button(f.page, "Erase the history");
  erase.fire("click");
  await flush();
  assert.equal(erase.disabled, true);
  erase.fire("click");
  assert.equal(sent("flow_clear").length, 1);
  fail(new Error("History file is locked"));
  await flush();
  assert.equal(erase.disabled, false);
  assert.match(f.page.querySelector(".hub-warn").textContent, /locked/);
  f.write(async () => {});
  erase.fire("click");
  await flush();
  assert.equal(f.page.querySelector(".hub-warn").hidden, true);
});

test("Erase everything retains confirmation on failure and resets it only after success", async t => {
  const f = await fixture(t, flowSettingsPage);
  f.write(async () => { throw new Error("Could not erase statistics"); });
  button(f.page, "Erase everything").fire("click");
  assert.equal(sent("flow_clear").length, 0);
  button(f.page, "Erase everything").fire("click");
  await flush();
  assert.match(f.page.textContent, /Erase the history and the statistics\?/);
  assert.match(f.page.querySelector(".hub-warn").textContent, /statistics/);
  f.write(async () => {});
  button(f.page, "Erase everything").fire("click");
  await flush();
  assert.doesNotMatch(f.page.textContent, /Erase the history and the statistics\?/);
  assert.equal(f.page.querySelector(".hub-warn").hidden, true);
  assert.deepEqual(sent("flow_clear"), [{ everything: true }, { everything: true }]);
});

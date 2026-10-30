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
const { flowSettingsPage } = await import("../src/hub/pages/flowsettings.ts");
const flush = () => new Promise(resolve => setTimeout(resolve, 0));

test("the manual thread choice waits for saving and restores the stored value on failure", async t => {
  const status = {
    prefs: { enabled: false, key: "right_ctrl", keepDays: 30, mic: "", speechThreads: 0 },
    models: { parakeet: { state: "ready" }, downloadMb: 700 },
    performance: { provider: "cpu", availableThreads: 4, threads: 2, automatic: true, measured: true, tuning: false, error: null },
    mics: [], keys: "ok", platform: "windows",
  };
  let finish, calls = 0;
  const page = root();
  const ctx = { hero: root, status, refresh: async () => status, setPrefs: change => {
    calls++;
    return new Promise((resolve, reject) => { finish = ok => {
      if (ok) { change(status.prefs); resolve(); } else reject(new Error("Settings file locked"));
    }; });
  } };
  await flowSettingsPage(page, ctx);
  t.after(() => ctx.onLeave?.());
  const choice = page.find("select").find(s => s.find("option").some(o => o.textContent === "Automatic (measured on this computer)"));
  assert.equal(choice.value, "0");
  choice.value = "1";
  choice.fire("change");
  assert.equal(choice.disabled, true);
  assert.equal(status.prefs.speechThreads, 0);
  finish(false);
  await flush();
  assert.equal(choice.value, "0");
  assert.equal(choice.disabled, false);
  choice.value = "1";
  choice.fire("change");
  finish(true);
  await flush();
  assert.equal(choice.value, "1");
  assert.equal(status.prefs.speechThreads, 1);
  assert.equal(status.prefs.mic, "");
  assert.equal(calls, 2);
});

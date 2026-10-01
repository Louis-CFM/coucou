import assert from "node:assert/strict";
import { test } from "node:test";
import { build } from "esbuild";

const { outputFiles } = await build({
  entryPoints: ["src/views/codex-model-picker.ts"], bundle: true, write: false,
  format: "esm", platform: "node",
  plugins: [{ name: "picker-fixtures", setup(api) {
    api.onResolve({ filter: /core\/bridge$/ }, () => ({ path: "bridge", namespace: "fixture" }));
    api.onResolve({ filter: /^\.\/dom$/ }, () => ({ path: "dom", namespace: "fixture" }));
    api.onLoad({ filter: /.*/, namespace: "fixture" }, ({ path }) => ({ contents: path === "bridge"
      ? "export const Bridge = { codexModels: mode => globalThis.pickerLoad(mode) };"
      : `export function h(tag, attrs) { return {
          ...attrs, value: attrs.value ?? '', children: [], events: {},
          replaceChildren(...items) { this.children = items; },
          addEventListener(name, callback) { this.events[name] = callback; }
        }; }`, loader: "js" }));
  } }],
});
const { codexModelPicker } = await import(`data:text/javascript;base64,${Buffer.from(outputFiles[0].text).toString("base64")}`);
const catalog = [{ model: "real-model", displayName: "Real Model", isDefault: true }];

test("catalog uses display labels and clears an unavailable saved slug", async () => {
  globalThis.pickerLoad = async () => catalog;
  let cleared = 0;
  const picker = codexModelPicker("chat-model", () => cleared++);
  picker.sync("subscription", "gpt-6.1-sol");
  await picker.ready();
  assert.equal(cleared, 1);
  assert.equal(picker.select.value, "");
  assert.deepEqual(picker.select.children.map(o => [o.value, o.text]), [["", "Default · Real Model"], ["real-model", "Real Model"]]);
});

test("known model remains selected and mode changes ignore stale catalog replies", async () => {
  const waiting = [];
  globalThis.pickerLoad = mode => new Promise(resolve => waiting.push({ mode, resolve }));
  let cleared = 0;
  const picker = codexModelPicker("", () => cleared++);
  picker.sync("subscription", "old-model");
  picker.sync("api", "real-model");
  waiting[1].resolve(catalog);
  await picker.ready();
  waiting[0].resolve([{ model: "old-model", displayName: "Old", isDefault: true }]);
  await Promise.resolve();
  assert.equal(picker.select.value, "real-model");
  assert.equal(cleared, 0);
  assert.equal(picker.select.children.length, 2);
});

test("failed lookup keeps saved model from being sent, permits default, and retries on focus", async () => {
  globalThis.pickerLoad = async () => { throw new Error("signed out"); };
  const picker = codexModelPicker("", () => {});
  picker.sync("subscription", "unverified");
  await assert.rejects(picker.ready(), /Cannot verify/);
  assert.match(picker.select.title, /signed out/);
  assert.equal(picker.select.disabled, false);
  assert.equal(picker.select.value, "unverified");
  assert.equal(picker.select.children.at(-1).disabled, true);
  picker.sync("subscription", "");
  await picker.ready();
  assert.equal(picker.select.value, "");
  globalThis.pickerLoad = async () => catalog;
  picker.select.events.focus();
  await picker.ready();
  assert.equal(picker.select.children.length, 2);
});

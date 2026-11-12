import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import ts from "typescript";
import { installFakeDom } from "./fakedom.mjs";
import { calls, internals, sent } from "./tauri.mjs";

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
document.documentElement = { lang: "en" };
document.visibilityState = "hidden";
Object.getPrototypeOf(root()).disabled = false;
Object.getPrototypeOf(root()).querySelectorAll = function (selector) {
  const tags = selector.split(",").map(tag => tag.trim().toUpperCase());
  return [...this.walk()].filter(el => tags.includes(el.tagName));
};
const { dictionaryPage, snippetsPage } = await import("../src/hub/pages/words.ts");
const { stylesPage } = await import("../src/hub/pages/styles.ts");
const flush = () => new Promise(resolve => setTimeout(resolve, 0));
const originalInvoke = internals.invoke;
const button = (page, name) => page.find("button").find(b => b.textContent === name || b.getAttribute("aria-label") === name);
const error = page => page.querySelector(".hub-warn");

async function fixture(t, render, initial = {}) {
  calls.length = 0;
  const data = {
    words: { words: ["Coucou"], replacements: [] },
    snippets: [{ id: "one", trigger: "signature", text: "Original signature" }],
    styles: [{ id: "mail", name: "Mail", style: "polished" }],
    ...initial,
  };
  let write = async () => {};
  t.mock.method(internals, "invoke", async (cmd, args) => {
    const fallback = await originalInvoke(cmd, args);
    if (cmd === "flow_running_apps") return [{ id: "editor", name: "Editor" }];
    for (const kind of ["words", "snippets", "styles"]) {
      if (cmd === `flow_${kind}`) return structuredClone(data[kind]);
      if (cmd === `flow_set_${kind}`) {
        await write(cmd, args);
        data[kind] = structuredClone(args[kind]);
        return;
      }
    }
    return fallback;
  });
  const page = root();
  const status = { prefs: { cleanup: true, defaultStyle: "natural" } };
  await render(page, { hero: root, status, refresh: async () => status, setPrefs: async change => change(status.prefs) });
  await flush();
  return { page, data, write: fn => { write = fn; } };
}

test("dictionary writes wait for disk, prevent duplicate submits and retain input on failure", async t => {
  const f = await fixture(t, dictionaryPage);
  const input = f.page.find("input")[0];
  input.value = "Parakeet";
  let reject;
  f.write(() => new Promise((_, fail) => { reject = fail; }));
  const add = button(f.page, "Add");
  add.fire("click");
  await flush();
  assert.equal(add.disabled, true);
  add.fire("click");
  await flush();
  assert.equal(sent("flow_set_words").length, 1);
  assert.equal(input.value, "Parakeet");
  assert.deepEqual(f.data.words.words, ["Coucou"]);
  reject(new Error("Dictionary destination is read-only"));
  await flush();
  assert.equal(add.disabled, false);
  assert.equal(input.value, "Parakeet");
  assert.equal(error(f.page).hidden, false);
  assert.match(error(f.page).textContent, /read-only/);
  assert.doesNotMatch(f.page.querySelector(".hub-chips").textContent, /Parakeet/);
  f.write(async () => {});
  add.fire("click");
  await flush();
  assert.deepEqual(f.data.words.words, ["Coucou", "Parakeet"]);
  assert.equal(input.value, "");
  assert.equal(error(f.page).hidden, true);
});

test("dictionary deletion and replacement failures keep the saved values and unfinished form", async t => {
  const f = await fixture(t, dictionaryPage);
  f.write(async () => { throw new Error("Disk full"); });
  button(f.page, "Delete").fire("click");
  await flush();
  assert.match(f.page.querySelector(".hub-chips").textContent, /Coucou/);
  const [, from, to] = f.page.find("input");
  from.value = "cloud code";
  to.value = "Claude Code";
  const add = f.page.find("button").filter(b => b.textContent === "Add")[1];
  add.fire("click");
  await flush();
  assert.equal(from.value, "cloud code");
  assert.equal(to.value, "Claude Code");
  assert.deepEqual(f.data.words.replacements, []);
  f.write(async () => {});
  add.fire("click");
  await flush();
  assert.equal(f.data.words.replacements.length, 1);
  assert.equal(f.data.words.replacements[0].to, "Claude Code");
  button(f.page, "Delete").fire("click");
  await flush();
  assert.deepEqual(f.data.words.words, []);
  assert.equal(f.data.words.replacements.length, 1);
});

test("a failed snippet edit retains the draft and original list until a successful retry", async t => {
  const f = await fixture(t, snippetsPage);
  button(f.page, "Edit").fire("click");
  const text = f.page.find("textarea")[0];
  text.value = "Updated signature";
  f.write(async () => { throw new Error("Disk full"); });
  button(f.page, "Save").fire("click");
  await flush();
  assert.equal(text.value, "Updated signature");
  assert.match(f.page.textContent, /Edit the snippet/);
  assert.match(f.page.querySelector(".hub-snippet-text").textContent, /Original signature/);
  assert.equal(error(f.page).hidden, false);
  f.write(async () => {});
  button(f.page, "Save").fire("click");
  await flush();
  assert.equal(f.data.snippets[0].text, "Updated signature");
  assert.equal(text.value, "");
  assert.equal(error(f.page).hidden, true);
});

test("a pending snippet save cannot race a second save or clear its draft", async t => {
  const f = await fixture(t, snippetsPage);
  f.page.find("input")[0].value = "greeting";
  f.page.find("textarea")[0].value = "Hello there";
  let finish;
  f.write(() => new Promise(resolve => { finish = resolve; }));
  const save = button(f.page, "Save");
  save.fire("click");
  await flush();
  save.fire("click");
  await flush();
  assert.equal(sent("flow_set_snippets").length, 1);
  assert.equal(f.page.find("textarea")[0].value, "Hello there");
  assert.equal(save.disabled, true);
  finish();
  await flush();
  assert.equal(f.data.snippets.length, 2);
  assert.equal(save.disabled, false);
});

test("failed snippet deletion keeps the entry and a successful deletion clears its editor", async t => {
  const f = await fixture(t, snippetsPage);
  button(f.page, "Edit").fire("click");
  f.write(async () => { throw new Error("Disk full"); });
  button(f.page, "Delete").fire("click");
  await flush();
  assert.match(f.page.querySelector(".hub-snippet-text").textContent, /Original signature/);
  f.write(async () => {});
  button(f.page, "Delete").fire("click");
  await flush();
  assert.equal(f.data.snippets.length, 0);
  assert.equal(f.page.find("textarea")[0].value, "");
  assert.match(f.page.textContent, /New snippet/);
});

test("a failed app-style change restores the persisted choice and allows retry", async t => {
  const f = await fixture(t, stylesPage);
  const appSelect = () => f.page.find("select").at(-1);
  f.write(async () => { throw new Error("Styles destination is read-only"); });
  appSelect().value = "verbatim";
  appSelect().fire("change");
  await flush();
  assert.equal(appSelect().value, "polished");
  assert.equal(f.data.styles[0].style, "polished");
  assert.equal(error(f.page).hidden, false);
  f.write(async () => {});
  appSelect().value = "verbatim";
  appSelect().fire("change");
  await flush();
  assert.equal(f.data.styles[0].style, "verbatim");
  assert.equal(error(f.page).hidden, true);
});

test("adding and deleting app styles leaves the saved list intact when writing fails", async t => {
  const f = await fixture(t, stylesPage);
  const add = f.page.find("select").find(select => select.find("option").some(option => option.textContent === "+ Add an app"));
  const initialSelects = f.page.find("select").length;
  f.write(async () => { throw new Error("Disk full"); });
  add.value = "editor\nEditor";
  add.fire("change");
  await flush();
  assert.equal(f.data.styles.length, 1);
  assert.equal(f.page.find("select").length, initialSelects);
  f.write(async () => {});
  add.value = "editor\nEditor";
  add.fire("change");
  await flush();
  assert.deepEqual(f.data.styles[1], { id: "editor", name: "Editor", style: "natural" });
  f.write(async () => { throw new Error("Disk full"); });
  button(f.page, "Delete").fire("click");
  await flush();
  assert.equal(f.page.find("select").length, initialSelects + 1);
  f.write(async () => {});
  button(f.page, "Delete").fire("click");
  await flush();
  assert.deepEqual(f.data.styles.map(s => s.id), ["editor"]);
});

test("a repeated style event does not unlock the editor while its first save is pending", async t => {
  const f = await fixture(t, stylesPage);
  let finish;
  f.write(() => new Promise(resolve => { finish = resolve; }));
  const choice = f.page.find("select").at(-1);
  choice.value = "verbatim";
  choice.fire("change");
  await flush();
  choice.fire("change");
  await flush();
  assert.equal(sent("flow_set_styles").length, 1);
  assert.equal(f.page.find("select").at(-1).disabled, true);
  finish();
  await flush();
  assert.equal(f.data.styles[0].style, "verbatim");
  assert.equal(f.page.find("select").at(-1).disabled, false);
});

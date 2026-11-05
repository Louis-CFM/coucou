// Regression coverage for #839, adapted to the shared settings index.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { installFakeDom } from "./fakedom.mjs";
installFakeDom();
const { setLanguage, t } = await import("../src/i18n/i18n.ts");
const { SETTINGS_ENTRIES, searchSettings, normalize } = await import("../src/hub/search.ts");

const title = (page) => t(page === "general" ? "General" : "Settings");
function inLanguage(lang, fn) {
  setLanguage(lang);
  try { fn(); } finally { setLanguage("en"); }
}

test("Spanish and English both find Language without changing the UI language", () => {
  inLanguage("es", () => {
    for (const query of ["idioma", "language"]) {
      const hit = searchSettings(query, title).find((h) => h.entry.id === "general.language");
      assert.ok(hit, query);
      assert.equal(t(hit.entry.title), "Idioma");
    }
  });
});

test("English labels resolve to the localized label and stable box anchor", () => {
  inLanguage("es", () => {
    const hits = searchSettings("paste last", title);
    const hit = hits.find((h) => h.entry.id === "flow.keys");
    assert.ok(hit);
    assert.equal(hit.label, t("Paste the last dictation again"));
    assert.notEqual(hit.label, "Paste the last dictation again");
  });
});

test("French accents and capitals do not matter", () => {
  assert.equal(normalize("R\u00e9glages"), "reglages");
  inLanguage("fr", () => {
    assert.ok(searchSettings("REGLAGES", title).length > 0);
  });
});

test("sidebar pages are searchable and do not request a box anchor", () => {
  const page = { id: "page.shortcuts", page: "shortcuts", title: "Shortcuts", terms: [], isPage: true };
  const [hit] = searchSettings("shortcuts", title, [page, ...SETTINGS_ENTRIES]);
  assert.equal(hit.entry, page);
  assert.equal(hit.entry.isPage, true);
});

test("every query word is required, in any order", () => {
  const a = searchSettings("open sounds folder", title).map((h) => h.id);
  assert.ok(a.length > 0);
  assert.deepEqual(searchSettings("folder sounds open", title).map((h) => h.id), a);
  assert.deepEqual(searchSettings("sounds zzz", title), []);
});

test("empty queries and result cap follow the current search contract", () => {
  assert.deepEqual(searchSettings("", title), []);
  assert.deepEqual(searchSettings("   ", title), []);
  assert.ok(searchSettings("e", title).length <= 30);
});

test("the index targets current sidebar pages including Mail", () => {
  const shell = readFileSync(new URL("../src/hub/shell.ts", import.meta.url), "utf8");
  const ids = new Set([...shell.matchAll(/\{ id: "(\w+)", icon:/g)].map((m) => m[1]));
  for (const entry of SETTINGS_ENTRIES) assert.ok(ids.has(entry.page), entry.id);
  assert.ok(ids.has("mailRules"));
});

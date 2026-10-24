// The search box of the Coucou window (src/hub/search.ts): what you type finds
// a page or a setting, in the language you read or in English, ignoring accents.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();

const { setLanguage, isComplete, t } = await import("../src/i18n/i18n.ts");
const { SETTINGS, searchSettings, normalize } = await import("../src/hub/search.ts");

// shell.ts imports its stylesheet, which Node cannot load: the pages are
// listed here as the sidebar shows them, and their ids are read from the
// source below to be sure they are the real ones.
const FLOW = [
  ["dictation", "Dictation"], ["notes", "Notetaker"], ["insights", "Statistics"], ["dictionary", "Dictionary"],
  ["snippets", "Snippets"], ["styles", "Styles"], ["flowsettings", "Settings"],
];
const NOTCH = [
  ["general", "General"], ["pills", "Active pills"], ["agents", "Agents"], ["chat", "Chat"], ["voice", "OK Coucou"],
  ["integrations", "Integrations"], ["phone", "Android phone"], ["shortcuts", "Shortcuts"],
];

/** The pages as the sidebar lists them, in the current language. */
const pages = () => [
  ...FLOW.map(([id, title]) => ({ id, title: id === "voice" ? title : t(title), group: "Flow" })),
  ...NOTCH.map(([id, title]) => ({ id, title: id === "voice" ? title : t(title), group: "Notch" })),
];

function inLanguage(lang, fn) {
  setLanguage(lang);
  try {
    fn();
  } finally {
    setLanguage("en");
  }
}

test("\"idioma\" leads to General → Language", () => {
  inLanguage("es", () => {
    const [first] = searchSettings("idioma", pages());
    assert.equal(first.page, "general");
    assert.equal(first.text, "Idioma");
    assert.equal(first.setting, true);
    assert.equal(first.where, "Notch · General");
  });
});

test("English works in any language, and so does the language's own word", () => {
  inLanguage("es", () => {
    assert.equal(searchSettings("language", pages())[0].page, "general");
    assert.equal(searchSettings("microfono", pages()).some((h) => h.page === "flowsettings"), true);
  });
  assert.equal(searchSettings("language", pages())[0].text, "Language");
});

test("capitals and accents do not matter", () => {
  assert.equal(normalize("Réglages"), "reglages");
  inLanguage("fr", () => {
    const hits = searchSettings("REGLAGES", pages());
    assert.equal(hits[0].setting, false);
    assert.equal(hits[0].page, "flowsettings");
  });
});

test("a page matches by its name and just opens", () => {
  const [first] = searchSettings("shortcuts", pages());
  assert.deepEqual(first, { page: "shortcuts", text: "Shortcuts", where: "Notch", setting: false });
});

test("every word has to be there, in any order", () => {
  const hits = searchSettings("clock island", pages());
  assert.equal(hits[0].text, "Show clock in the island");
  assert.deepEqual(searchSettings("clock zzz", pages()), []);
});

test("a name that starts with the query comes before one that only has it", () => {
  const hits = searchSettings("dictat", pages());
  assert.ok(hits.length > 2);
  assert.equal(hits[0].text, "Dictation"); // the page starts with it
  assert.equal(hits[0].setting, false);
  // The settings that only have it inside a word keep the order of the list.
  const texts = hits.map((h) => h.text);
  assert.ok(texts.indexOf("Hold to dictate") < texts.indexOf("Paste the last dictation again"));
});

test("an empty or blank query finds nothing", () => {
  assert.deepEqual(searchSettings("", pages()), []);
  assert.deepEqual(searchSettings("   ", pages()), []);
});

test("at most twenty results", () => {
  assert.ok(searchSettings("e", pages()).length <= 20);
});

test("every setting listed is on a page of the window and translated everywhere", () => {
  const shell = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../src/hub/shell.ts"), "utf8");
  const real = new Set([...shell.matchAll(/\{ id: "(\w+)", icon:/g)].map((m) => m[1]));
  assert.deepEqual([...real].sort(), pages().map((p) => p.id).sort());
  const ids = new Set(pages().map((p) => p.id));
  for (const s of SETTINGS) {
    assert.ok(ids.has(s.page), `${s.key}: no page "${s.page}"`);
    assert.ok(isComplete(s.key), `${s.key} is not translated in every language`);
  }
});

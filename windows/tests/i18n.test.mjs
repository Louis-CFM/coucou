// Interface language (src/i18n): lookup, fallback, interpolation and plurals,
// the generated table against the Mac's catalog, every key the code uses being
// translated, and no known user-facing English left outside t() in the views.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();

const {
  LANGUAGES, LANGUAGE_CODES, N_, dayMonth, isComplete, isRtl, labels, language, lookup, monthShort,
  onLanguageChange, resolveLanguage, setLanguage, t, tl, tn, weekdayShort,
} = await import("../src/i18n/i18n.ts");
const { h, relabel, liveTextCount } = await import("../src/views/dom.ts");
const { generate, convertFormat, LANGUAGES: GENERATED_LANGUAGES } = await import("../scripts/gen-strings.mjs");

const here = dirname(fileURLToPath(import.meta.url));
const WINDOWS = join(here, "..");
const MAC = JSON.parse(readFileSync(join(WINDOWS, "src/i18n/strings.json"), "utf8"));
const EXTRA = JSON.parse(readFileSync(join(WINDOWS, "src/i18n/extra.json"), "utf8"));
const OTHERS = LANGUAGE_CODES.filter((l) => l !== "en");

/** Runs `fn` in `lang`, then puts English back for the other tests. */
function inLanguage(lang, fn) {
  setLanguage(lang);
  try {
    fn();
  } finally {
    setLanguage("en");
  }
}

// ── Lookup ────────────────────────────────────────────────────────────────────

test("English is the key itself, other languages come from either table", () => {
  assert.equal(language(), "en");
  assert.equal(t("Allow"), "Allow");
  inLanguage("fr", () => {
    assert.equal(t("Allow"), "Autoriser"); // the Mac's catalog
    assert.equal(t("Open the chat"), "Ouvrir le chat"); // extra.json
  });
  inLanguage("zh-Hans", () => assert.equal(t("Cancel"), "取消"));
});

test("a string nobody translated falls back to its English text", () => {
  inLanguage("ru", () => {
    assert.equal(t("Some brand new sentence."), "Some brand new sentence.");
    assert.equal(t("Hello {name}", { name: "Mochi" }), "Hello Mochi");
  });
});

test("placeholders are filled in every language, unknown ones are left as they are", () => {
  assert.equal(t("Uploading {name}", { name: "a.pdf" }), "Uploading a.pdf");
  assert.equal(t("Uploading {name}"), "Uploading {name}");
  inLanguage("hi", () => assert.equal(t("Uploading {name}", { name: "a.pdf" }), "a.pdf अपलोड हो रहा है"));
  inLanguage("es", () => assert.equal(t("in {h} h {m}", { h: 1, m: 20 }), "en 1 h 20"));
  assert.equal(t("{used}/{max} slots in use — the main tool doesn't take one.", { used: 2, max: 4 }),
    "2/4 slots in use — the main tool doesn't take one.");
});

test("plurals follow each language's rules", () => {
  const files = (n) => tn("{count} repo", "{count} repos", n);
  assert.equal(files(1), "1 repo");
  assert.equal(files(3), "3 repos");
  inLanguage("fr", () => {
    assert.equal(files(1), "1 dépôt");
    assert.equal(files(0), "0 dépôt"); // French: 0 and 1 are singular
    assert.equal(files(5), "5 dépôts");
  });
  inLanguage("ru", () => {
    assert.equal(files(1), "1 репозиторий");
    assert.equal(files(3), "3 репозитория");
    assert.equal(files(5), "5 репозиториев");
    assert.equal(files(21), "21 репозиторий");
  });
  inLanguage("zh-Hans", () => assert.equal(files(7), "7 个仓库"));
  // The Mac's plural entry: Spanish one/other.
  inLanguage("es", () => {
    assert.equal(tn("✓ Connected · {count} model", "✓ Connected · {count} models", 1), "✓ Conectado · 1 modelo");
    assert.equal(tn("✓ Connected · {count} model", "✓ Connected · {count} models", 2), "✓ Conectado · 2 modelos");
  });
});

test("labels() tables and dates read in the current language", () => {
  const table = labels({ bow: N_("Bow"), hat: N_("Party hat") });
  assert.equal(table.bow, "Bow");
  inLanguage("fr", () => {
    assert.equal(table.bow, "Nœud");
    assert.deepEqual(Object.keys(table), ["bow", "hat"]);
    assert.match(monthShort(9), /^oct/);
  });
  assert.equal(monthShort(9), "Oct");
  assert.equal(weekdayShort(1), "Mon");
  assert.equal(dayMonth(8, 28), "Sep 28");
  inLanguage("es", () => assert.match(dayMonth(8, 28), /^28 sept?/));
});

// ── Choosing the language ─────────────────────────────────────────────────────

test("System follows the system's language when Coucou has it, else English", () => {
  assert.equal(resolveLanguage("", ["fr-FR", "en-US"]), "fr");
  assert.equal(resolveLanguage("", ["it-IT", "es-MX"]), "es");
  assert.equal(resolveLanguage("", ["pt-PT"]), "pt-BR");
  assert.equal(resolveLanguage("", ["pt"]), "pt-BR");
  assert.equal(resolveLanguage("", ["zh-CN"]), "zh-Hans");
  assert.equal(resolveLanguage("", ["zh-TW"]), "en"); // Traditional is not one of ours
  assert.equal(resolveLanguage("", ["ar-EG"]), "ar");
  assert.equal(resolveLanguage("", ["it-IT"]), "en");
  assert.equal(resolveLanguage("", []), "en");
  // A picked language wins; one this build doesn't know means System.
  assert.equal(resolveLanguage("ru", ["fr-FR"]), "ru");
  assert.equal(resolveLanguage("xx", ["bn-IN"]), "bn");
});

test("the picker offers the Mac's languages, Arabic reads right to left", () => {
  assert.deepEqual(LANGUAGES.map((l) => l.code), ["en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt-BR", "ru", "id", "de"]);
  assert.equal(isRtl("ar"), true);
  assert.equal(OTHERS.some((l) => l !== "ar" && isRtl(l)), false);
});

test("German translates both tables, fills placeholders and falls back to English", () => {
  inLanguage("de", () => {
    assert.equal(t("Allow"), "Zulassen");
    assert.equal(t("Deny"), "Ablehnen");
    assert.equal(t("Open the chat"), "Chat öffnen");
    assert.equal(t("Uploading {name}", { name: "Grüße.pdf" }), "Grüße.pdf wird hochgeladen");
    assert.equal(t("API error {code}", { code: 401 }), "API-Fehler 401");
    assert.equal(t("A string nobody translated"), "A string nobody translated");
    assert.match(monthShort(9), /^Okt/);
    assert.match(weekdayShort(1), /^Mo/);
    assert.match(dayMonth(8, 28), /^28\./);
  });
});

test("German selects singular only for one in both plural catalogs", () => {
  inLanguage("de", () => {
    for (const count of [0, 1, 2, 21]) {
      assert.equal(tn("{count} repo", "{count} repos", count),
        `${count} ${count === 1 ? "Repository" : "Repositorys"}`);
      assert.equal(tn("{count} contribution", "{count} contributions", count),
        `${count} ${count === 1 ? "Beitrag" : "Beiträge"}`);
      assert.equal(tn("✓ Connected · {count} model", "✓ Connected · {count} models", count),
        `✓ Verbunden · ${count} ${count === 1 ? "Modell" : "Modelle"}`);
    }
  });
});

test("German regional locales select Deutsch and apply left-to-right document metadata", () => {
  for (const tag of ["de", "de-DE", "de-AT", "de-CH", "de_DE.UTF-8"]) {
    assert.equal(resolveLanguage("", [tag]), "de");
  }
  assert.equal(resolveLanguage("de", ["fr-FR"]), "de");
  assert.equal(resolveLanguage("fr", ["de-DE"]), "fr");
  assert.equal(resolveLanguage("", ["it-IT", "de-DE", "es-MX"]), "de");
  assert.equal(LANGUAGES.find((l) => l.code === "de")?.name, "Deutsch");
  const previousRoot = document.documentElement;
  document.documentElement = { lang: "en", dataset: {} };
  try {
    inLanguage("de", () => {
      assert.equal(isRtl(), false);
      assert.equal(document.documentElement.lang, "de");
      assert.equal(document.documentElement.dataset.dir, "ltr");
    });
  } finally {
    if (previousRoot === undefined) delete document.documentElement;
    else document.documentElement = previousRoot;
  }
});

test("German Apple translations preserve format specifiers and provide plural forms", () => {
  const catalog = JSON.parse(readFileSync(join(WINDOWS, "../NotchBuddy/Resources/Localizable.xcstrings"), "utf8"));
  const specifiers = (text) => [...text.matchAll(/%(?:\d+\$)?(?:lld|ld|lu|@|d|u|f|%)/g)]
    .map((m) => m[0]).sort();
  for (const [key, entry] of Object.entries(catalog.strings)) {
    const source = entry.localizations.en;
    const german = entry.localizations.de;
    assert.ok(german, `Missing German Apple translation: ${key}`);
    if (source.variations?.plural) {
      assert.deepEqual(Object.keys(german.variations.plural).sort(), ["one", "other"]);
      for (const form of ["one", "other"]) {
        assert.equal(german.variations.plural[form].stringUnit.state, "translated");
        assert.deepEqual(specifiers(german.variations.plural[form].stringUnit.value),
          specifiers(source.variations.plural[form].stringUnit.value), key);
      }
    } else {
      assert.equal(german.stringUnit.state, "translated");
      assert.ok(german.stringUnit.value.length, key);
      assert.deepEqual(specifiers(german.stringUnit.value), specifiers(source.stringUnit.value), key);
    }
  }
});

test("generated, Rust and Apple language registrations agree with the picker", () => {
  assert.deepEqual(GENERATED_LANGUAGES, LANGUAGE_CODES);
  assert.deepEqual(MAC.languages, LANGUAGE_CODES);
  const rust = readFileSync(join(WINDOWS, "src-tauri/src/i18n.rs"), "utf8");
  const registered = rust.match(/pub const LANGUAGES: \[&str; (\d+)\] = (\[[^;]+\]);/);
  assert.ok(registered);
  assert.equal(Number(registered[1]), LANGUAGE_CODES.length);
  assert.deepEqual(JSON.parse(registered[2]), LANGUAGE_CODES);
  const expected = [...LANGUAGE_CODES].sort();
  for (const file of ["Info.plist", "InfoAppStore.plist"]) {
    const plist = readFileSync(join(WINDOWS, "../NotchBuddy/Resources", file), "utf8");
    const array = plist.match(/<key>CFBundleLocalizations<\/key>\s*<array>([\s\S]*?)<\/array>/);
    assert.ok(array, file);
    assert.deepEqual([...array[1].matchAll(/<string>([^<]+)<\/string>/g)].map((m) => m[1]).sort(), expected, file);
  }
  const project = readFileSync(join(WINDOWS, "../NotchBuddy/project.yml"), "utf8");
  const arrays = [...project.matchAll(/CFBundleLocalizations:\r?\n((?:[ \t]+- [^\r\n]+\r?\n)+)/g)];
  assert.equal(arrays.length, 2);
  for (const array of arrays) {
    assert.deepEqual([...array[1].matchAll(/- ([^\r\n]+)/g)].map((m) => m[1]).sort(), expected);
  }
  const swift = readFileSync(join(WINDOWS, "../NotchBuddy/Sources/App/SettingsView.swift"), "utf8");
  assert.match(swift, /Text\("Deutsch"\)\.tag\("de"\)/);
});

test("a language change relabels what was built, in place, and says so once", () => {
  let told = 0;
  const off = onLanguageChange(() => told++);
  const button = h("button", { title: tl("Settings") }, tl("Cancel"));
  const label = h("span", { text: tl("Uploading {name}", { name: "x.png" }) });
  const replaced = h("span", { text: tl("Allow") });
  replaced.textContent = "dynamic text"; // some code wrote over it since
  assert.ok(liveTextCount() >= 3);

  setLanguage("fr");
  assert.equal(told, 1);
  assert.equal(button.getAttribute("title"), "Réglages");
  assert.equal(button.textContent, "Annuler");
  assert.equal(label.textContent, "Envoi de x.png en cours");
  assert.equal(replaced.textContent, "dynamic text");
  setLanguage("fr"); // same language: nothing to do
  assert.equal(told, 1);

  setLanguage("en");
  assert.equal(button.textContent, "Cancel");
  relabel();
  assert.equal(button.getAttribute("title"), "Settings");
  off();
});

// ── The tables ────────────────────────────────────────────────────────────────

test("strings.json is what the generator makes of the Mac's catalog", () => {
  const catalog = JSON.parse(readFileSync(join(WINDOWS, "../NotchBuddy/Resources/Localizable.xcstrings"), "utf8"));
  assert.deepEqual(generate(catalog), MAC);
});

test("the generator turns format specifiers into placeholders", () => {
  assert.equal(convertFormat("Chat with %@", ["name"]), "Chat with {name}");
  assert.equal(convertFormat("in %lld h %lld", ["h", "m"]), "in {h} h {m}");
  assert.equal(convertFormat("%2$@ then %1$@"), "{1} then {0}");
  assert.equal(convertFormat("100%% sure"), "100% sure");
});

const placeholders = (s) => [...new Set(s.match(/\{\w+\}/g) ?? [])].sort();

for (const [name, table] of [["strings.json", MAC.strings], ["extra.json", EXTRA.strings]]) {
  test(`${name}: every string in every language, with the key's placeholders`, () => {
    for (const [key, entry] of Object.entries(table)) {
      for (const lang of OTHERS) {
        const value = entry[lang];
        assert.ok(value !== undefined, `${name}: ${JSON.stringify(key)} has no ${lang}`);
        const forms = typeof value === "string" ? [value] : Object.values(value);
        for (const form of forms) {
          const got = placeholders(form);
          // A plural form may write the number out ("one" in Arabic).
          const ok = typeof value === "string"
            ? JSON.stringify(got) === JSON.stringify(placeholders(key))
            : got.every((p) => placeholders(key).includes(p));
          assert.ok(ok, `${name}: ${lang} ${JSON.stringify(form)} for ${JSON.stringify(key)}`);
        }
      }
    }
  });
}

test("extra.json never shadows a string of the Mac's", () => {
  for (const key of Object.keys(EXTRA.strings)) assert.ok(!(key in MAC.strings), key);
});

// ── Every key the code uses is translated ─────────────────────────────────────

function files(dir, ext) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...files(path, ext));
    else if (path.endsWith(ext)) out.push(path);
  }
  return out;
}

/** Source without comments (a doc example is not a key) or Rust test modules. */
function code(path) {
  // Windows checkouts have CRLF line endings.
  let text = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  const tests = text.indexOf("#[cfg(test)]\nmod tests");
  if (tests >= 0) text = text.slice(0, tests);
  return text.split("\n").filter((line) => !/^\s*(\/\/|\*|\/\*)/.test(line)).join("\n");
}

const STR = String.raw`"((?:[^"\\]|\\.)*)"`;
const unquote = (s) => JSON.parse(`"${s}"`);

function usedKeys() {
  const keys = new Map();
  const add = (key, path) => keys.set(key, relative(WINDOWS, path));
  for (const path of files(join(WINDOWS, "src"), ".ts")) {
    const text = code(path);
    for (const m of text.matchAll(new RegExp(String.raw`\b(?:t|tl|N_)\(\s*` + STR, "g"))) add(unquote(m[1]), path);
    // tn(one, other, n): the English plural is the key.
    for (const m of text.matchAll(new RegExp(String.raw`\btn\(\s*` + STR + String.raw`\s*,\s*` + STR, "g"))) add(unquote(m[2]), path);
  }
  for (const path of files(join(WINDOWS, "src-tauri/src"), ".rs")) {
    const text = code(path);
    for (const m of text.matchAll(new RegExp(String.raw`\b(?:t|tf|n_)\(\s*` + STR, "g"))) add(unquote(m[1]), path);
    for (const m of text.matchAll(new RegExp(String.raw`\btn\(\s*` + STR + String.raw`\s*,\s*` + STR, "g"))) add(unquote(m[2]), path);
  }
  return keys;
}

test("every string the code shows is translated in every language", () => {
  const keys = usedKeys();
  assert.ok(keys.size > 300, `only ${keys.size} keys found — has the scan broken?`);
  const missing = [...keys].filter(([key]) => !isComplete(key)).map(([key, path]) => `${path}: ${JSON.stringify(key)}`);
  assert.deepEqual(missing, []);
  // And the hand-written table carries nothing the code no longer uses.
  const unused = Object.keys(EXTRA.strings).filter((key) => !keys.has(key));
  assert.deepEqual(unused, []);
});

test("lookup() answers from the merged tables", () => {
  assert.equal(lookup("Allow", "en"), undefined);
  assert.equal(lookup("Allow", "pt-BR"), "Permitir");
  assert.equal(typeof lookup("{count} repos", "ru"), "object");
});

// ── No English left outside t() ───────────────────────────────────────────────
//
// Pragmatic: a literal in the views, the settings window, the island, the
// upload canvas or the recap that is exactly a translated string, and is not
// the argument of t() / tl() / tn() / N_(), is English that would stay English.

const CHECKED = ["src/views", "src/settings", "src/island", "src/upload", "src/recap", "src/mochi/wardrobe.ts", "src/main.ts"];
/** Literals that are a translated word but are values in the code, not text on screen. */
const NOT_TEXT = new Set([
  "file", // the kind of a chat context: { kind: "file" }
  "finished", // a task state and a pill badge
  "unknown", // a CI state
  "Resend", // the service's name (the Mac's "Resend" is a button: send again)
]);

test("no known user-facing English literal outside t() in the views and settings", () => {
  const translated = new Set(
    [...Object.entries(MAC.strings), ...Object.entries(EXTRA.strings)]
      .filter(([key, entry]) => OTHERS.some((l) => typeof entry[l] !== "string" || entry[l] !== key))
      .map(([key]) => key),
  );
  const offenders = [];
  for (const target of CHECKED) {
    const full = join(WINDOWS, target);
    const list = statSync(full).isDirectory() ? files(full, ".ts") : [full];
    for (const path of list) {
      const text = code(path);
      for (const m of text.matchAll(new RegExp(STR, "g"))) {
        let value;
        try {
          value = unquote(m[1]);
        } catch {
          continue;
        }
        if (!translated.has(value) || NOT_TEXT.has(value)) continue;
        const before = text.slice(Math.max(0, m.index - 400), m.index);
        if (/\b(?:t|tl|N_)\(\s*$/.test(before)) continue;
        if (/\btn\(\s*"(?:[^"\\]|\\.)*"\s*,\s*$/.test(before) || /\btn\(\s*$/.test(before)) continue;
        offenders.push(`${relative(WINDOWS, path)}: ${JSON.stringify(value)}`);
      }
    }
  }
  assert.deepEqual(offenders, []);
});

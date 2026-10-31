import test from "node:test";
import assert from "node:assert/strict";
import { normalize, words, match, searchSettings, SETTINGS_ENTRIES } from "../src/hub/search.ts";

test("SettingsSearch - words normalization and splitting", () => {
  assert.deepEqual(words("  Réglage   SON "), ["reglage", "son"]);
  assert.deepEqual(words("   "), []);
  assert.deepEqual(words("général"), ["general"]);
  assert.deepEqual(words("Türkçe Ayarlar"), ["turkce", "ayarlar"]);
  assert.deepEqual(words("Häufige Fragen"), ["haufige", "fragen"]);
});

test("SettingsSearch - match against box, title, and labels (Mac contract parity)", () => {
  const sound = {
    title: "Son",
    page: "Général",
    labels: ["Activer les sons", "Volume", "Ouvrir le dossier des sons"],
  };

  const m = (q) => match(words(q), sound.title, sound.page, sound.labels);

  // The box by its title or its page, whatever the accents and the case.
  assert.deepEqual(m("son"), { kind: "box" });
  assert.deepEqual(m("GENERAL"), { kind: "box" });
  assert.deepEqual(m("général son"), { kind: "box" });

  // A setting inside it.
  assert.deepEqual(m("volu"), { kind: "label", label: "Volume" });
  assert.deepEqual(m("dossier"), { kind: "label", label: "Ouvrir le dossier des sons" });

  // Every word somewhere; the label with most of them.
  assert.deepEqual(m("ouvrir dossier son"), { kind: "label", label: "Ouvrir le dossier des sons" });
  assert.deepEqual(m("volume general"), { kind: "label", label: "Volume" });

  // Not there.
  assert.equal(m("micro"), null);
  assert.equal(m("volume micro"), null, "every word must be found");
  assert.equal(m(""), null);
});

test("SettingsSearch - searchSettings searches entries across Flow, Notch and Mail", () => {
  const pageTitles = {
    dictation: "Dictation",
    flowsettings: "Settings",
    general: "General",
    agents: "Agents",
    mailOverview: "Overview",
    mailRules: "Rules",
    mailBanned: "Banned words",
    mailVIP: "VIP",
  };
  const getPageTitle = (p) => pageTitles[p] ?? p;

  // Search by box name
  const resKeys = searchSettings("keys", getPageTitle);
  assert.ok(resKeys.length > 0);
  assert.ok(resKeys.some((h) => h.entry.id === "flow.keys"));

  // Search by term inside box
  const resHandsfree = searchSettings("handsfree", getPageTitle);
  assert.ok(resHandsfree.length > 0);
  assert.ok(resHandsfree.some((h) => h.entry.id === "flow.keys"));

  // Search by sound in general
  const resSound = searchSettings("sound", getPageTitle);
  assert.ok(resSound.some((h) => h.entry.id === "general.sound"));

  // Search Mail entries
  const resMail = searchSettings("rules", getPageTitle);
  assert.ok(resMail.some((h) => h.entry.id === "mail.rules"));

  const resBanned = searchSettings("banned", getPageTitle);
  assert.ok(resBanned.some((h) => h.entry.id === "mail.banned"));

  // Empty query returns empty array
  assert.deepEqual(searchSettings("", getPageTitle), []);
  assert.deepEqual(searchSettings("   ", getPageTitle), []);

  // Unknown query returns empty array
  assert.deepEqual(searchSettings("nonexistentgibberishqueryxyz", getPageTitle), []);
});

test("SettingsSearch - SETTINGS_ENTRIES integrity and completeness", () => {
  assert.ok(SETTINGS_ENTRIES.length >= 30, "must include complete set of hub settings");
  const ids = new Set();
  for (const entry of SETTINGS_ENTRIES) {
    assert.ok(entry.id, "every entry must have an id");
    assert.ok(!ids.has(entry.id), `duplicate entry id: ${entry.id}`);
    ids.add(entry.id);
    assert.ok(entry.page, `entry ${entry.id} must define a page`);
    assert.ok(entry.title, `entry ${entry.id} must define a title`);
    assert.ok(Array.isArray(entry.terms), `entry ${entry.id} must define terms array`);
  }
});

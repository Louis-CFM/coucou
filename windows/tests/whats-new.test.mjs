// What's new after an update and the blue Mochi while one waits
// (src/whats-new/whats-new.ts): which entry, when the card shows, what it
// counts, and when Mochi is blue.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { NO_UPDATE } from "../src/core/update.ts";
import { BotEngine } from "../src/mochi/engine.ts";
import { WHATS_NEW_ICONS } from "../src/whats-new/icons.ts";
import {
  COFFEE_URL, ICON_NAMES, LATER_MS, compareVersions, decideOnLaunch, iconName, localized, releaseFor,
  releasePage, showsUpdateHint, soFar, updateWaiting, usedBefore,
} from "../src/whats-new/whats-new.ts";

const FILE = JSON.parse(readFileSync(new URL("../src/whats-new/whats-new.json", import.meta.url), "utf8"));
const PKG = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));

test("versions compare as numbers", () => {
  assert.equal(compareVersions("0.10.0", "0.9.3"), 1);
  assert.equal(compareVersions("0.5.1", "0.5"), 1);
  assert.equal(compareVersions("0.5", "0.5.0"), 0);
  assert.equal(compareVersions("0.5.0", "0.5.1"), -1);
  assert.equal(compareVersions("1.0.0", "0.99.99"), 1);
});

test("the entry of exactly the running version", () => {
  const file = { releases: [{ version: "0.6.0", items: [{ icon: "bell", title: { en: "A" }, detail: { en: "a" } }] }, { version: "0.5.9", items: [] }] };
  assert.equal(releaseFor(file, "0.6.0")?.version, "0.6.0");
  assert.equal(releaseFor(file, "0.6"), file.releases[0], "0.6 is 0.6.0");
  assert.equal(releaseFor(file, "0.5.9"), null, "an entry without items is no card");
  assert.equal(releaseFor(file, "0.7.0"), null);
  assert.equal(releaseFor(null, "0.6.0"), null);
  assert.equal(releaseFor({}, "0.6.0"), null);
});

test("the version this app ships has its entry, in every language", () => {
  const release = releaseFor(FILE, PKG.version);
  assert.ok(release, `whats-new.json has no entry for ${PKG.version}`);
  for (const item of release.items) {
    assert.ok(ICON_NAMES.includes(item.icon), item.icon);
    for (const lang of ["en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt-BR", "ru", "id", "de", "tr"]) {
      assert.ok(item.title[lang]?.trim(), `${item.icon} title ${lang}`);
      assert.ok(item.detail[lang]?.trim(), `${item.icon} detail ${lang}`);
    }
  }
});

test("every icon name has its drawing", () => {
  for (const name of ICON_NAMES) assert.ok(WHATS_NEW_ICONS[name], name);
  assert.equal(iconName("bell"), "bell");
  assert.equal(iconName("rocket"), "sparkles", "an unknown icon draws the sparkles");
});

test("the user's language, else English", () => {
  assert.equal(localized({ en: "Hello", fr: "Bonjour" }, "fr"), "Bonjour");
  assert.equal(localized({ en: "Hello", fr: " " }, "fr"), "Hello");
  assert.equal(localized({ en: "Hello" }, "tr"), "Hello");
  assert.equal(localized(null, "fr"), "");
});

test("at launch: an update shows the card once, a first install never", () => {
  const base = { current: "0.5.2", usedBefore: true, hasEntry: true };
  assert.deepEqual(decideOnLaunch({ ...base, lastSeen: "0.5.1" }), { show: true, record: true });
  assert.deepEqual(decideOnLaunch({ ...base, lastSeen: "0.5.2" }), { show: false, record: false }, "same version: nothing");
  assert.deepEqual(decideOnLaunch({ ...base, lastSeen: "0.6.0" }), { show: false, record: true }, "an older build: remember, say nothing");
  assert.deepEqual(decideOnLaunch({ ...base, lastSeen: "0.5.1", hasEntry: false }), { show: false, record: true }, "no entry: no card");
  // Coming from 0.5.1, which stored no version.
  assert.deepEqual(decideOnLaunch({ ...base, lastSeen: null }), { show: true, record: true });
  assert.deepEqual(decideOnLaunch({ ...base, lastSeen: null, usedBefore: false }), { show: false, record: true }, "a first install");
  assert.deepEqual(decideOnLaunch({ ...base, current: "", lastSeen: null }), { show: false, record: false });
});

test("signs of an earlier install", () => {
  const empty = { turns: [], decisions: [], prefs: {} };
  assert.equal(usedBefore({ consent: null, history: empty, dictations: 0, notes: 0 }), false);
  assert.equal(usedBefore({ consent: null, history: null, dictations: 0, notes: 0 }), false);
  assert.equal(usedBefore({ consent: false, history: empty, dictations: 0, notes: 0 }), true, "the update question was answered");
  assert.equal(usedBefore({ consent: null, history: { ...empty, decisions: [{ agent: "a", date: 1, decision: "allow" }] }, dictations: 0, notes: 0 }), true);
  assert.equal(usedBefore({ consent: null, history: empty, dictations: 2, notes: 0 }), true);
  assert.equal(usedBefore({ consent: null, history: empty, dictations: 0, notes: 1 }), true);
});

test("your Coucou so far: every kept number, zeros left out", () => {
  const turn = (start, end, linesAdded) => ({
    agent: "claude-code", project: "p", start, end, filesChanged: 1, linesAdded, linesRemoved: 3, commandsRun: 0, questions: 0,
  });
  const history = {
    // Two turns overlap: their time counts once (10 min + 20 min - 5 min overlap = 25 min).
    turns: [turn(0, 600, 40), turn(300, 1500, 60)],
    decisions: [
      { agent: "claude-code", date: 1, decision: "allow" },
      { agent: "claude-code", date: 2, decision: "always" },
      { agent: "claude-code", date: 3, decision: "deny" },
      { agent: "claude-code", date: 4, decision: "ask" },
    ],
    prefs: {},
  };
  const stats = soFar({ history, flow: { words: 1234.7, minutesSaved: 18.2, dictations: 9 }, calls: 2 });
  assert.deepEqual(stats, [
    { kind: "agentSessions", value: 2 },
    { kind: "agentTime", value: 25 },
    { kind: "linesAdded", value: 100 },
    { kind: "approvals", value: 3 },
    { kind: "words", value: 1234 },
    { kind: "saved", value: 18 },
    { kind: "calls", value: 2 },
  ]);
  assert.deepEqual(soFar({ history: null, flow: null, calls: 0 }), [], "a quiet install: nothing to count");
  assert.deepEqual(soFar({ history: null, flow: { words: 50, minutesSaved: 0, dictations: 3 }, calls: Number.NaN }), [{ kind: "words", value: 50 }]);
});

const out = (version = "0.6.0") => ({
  ...NO_UPDATE,
  consent: true,
  current: "0.5.2",
  latest: { version, headline: null, pageUrl: "https://github.com/Louis-CFM/coucou/releases/tag/windows-v0.6.0" },
});

test("Mochi is blue while a version waits", () => {
  const now = 1_800_000_000_000;
  assert.equal(updateWaiting(out(), null, now), true);
  assert.equal(updateWaiting({ ...out(), consent: null }, null, now), false, "never before the user said yes");
  assert.equal(updateWaiting({ ...out(), consent: false }, null, now), false);
  assert.equal(updateWaiting({ ...out(), latest: null }, null, now), false, "up to date");
  for (const phase of [{ kind: "downloading", fraction: 0.3 }, { kind: "verifying" }, { kind: "installing" }, { kind: "error", message: "x" }]) {
    assert.equal(updateWaiting({ ...out(), phase }, null, now), false, phase.kind);
  }
  assert.equal(updateWaiting(out(), { version: "0.6.0", at: now - 3600_000 }, now), false, "Later an hour ago");
  assert.equal(updateWaiting(out(), { version: "0.6.0", at: now - LATER_MS - 1 }, now), true, "Later yesterday: blue again");
  assert.equal(updateWaiting(out(), { version: "0.5.9", at: now - 60_000 }, now), true, "Later on another version");
  assert.equal(updateWaiting(out(), { version: "0.6.0", at: now + 3600_000 }, now), true, "a clock that went back");
});

test("the engine wears the arrow badge only over an idle or sleeping Mochi", () => {
  const engine = new BotEngine();
  engine.setUpdateHint([0.231, 0.51, 0.965]);
  assert.equal(engine.showsUpdateHint, true);
  engine.setState("working");
  assert.equal(engine.showsUpdateHint, false, "work in progress comes first");
  engine.setState("sleeping");
  assert.equal(engine.showsUpdateHint, true);
  engine.setUpdateHint(null);
  assert.equal(engine.showsUpdateHint, false);
});

test("the blue only when Mochi has nothing else to say", () => {
  assert.equal(showsUpdateHint(true, "idle", false), true);
  assert.equal(showsUpdateHint(true, "sleeping", false), true);
  assert.equal(showsUpdateHint(true, "working", false), false);
  assert.equal(showsUpdateHint(true, "approval", false), false);
  assert.equal(showsUpdateHint(true, "idle", true), false, "a waiting permission comes first");
  assert.equal(showsUpdateHint(false, "idle", false), false);
});

test("All changes and the coffee", () => {
  assert.equal(releasePage("windows", "0.5.2"), "https://github.com/Louis-CFM/coucou/releases/tag/windows-v0.5.2");
  assert.equal(releasePage("linux", "0.5.2"), "https://github.com/Louis-CFM/coucou/releases/tag/linux-v0.5.2");
  const site = readFileSync(new URL("../../docs/index.html", import.meta.url), "utf8");
  assert.ok(site.includes(COFFEE_URL), "the same link as the Coucou page");
});

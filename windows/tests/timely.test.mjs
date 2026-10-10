// The Timely card: today's entries from the poller's data (src/core/timely.ts)
// and the card drawn from them (src/views/integrations.ts). Parsing Timely's
// own answers and the token refresh are tested in src-tauri/src/timely.rs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();

const { entrySeconds, hm, localDay, loggedSeconds, readTimelyDay } = await import("../src/core/timely.ts");
const { hasIntegrationData, renderIntegrationCard } = await import("../src/views/integrations.ts");
const { State } = await import("../src/core/state.ts");

const NOW = new Date(2026, 9, 10, 14, 0, 0);
const TODAY = localDay(NOW);
const nowSecs = Math.floor(NOW.getTime() / 1000);

const entry = (over = {}) => ({
  id: 1, day: TODAY, project: "Website", client: "Acme", color: "#7b00ff", note: "",
  loggedSeconds: 1800, timerStartedOn: null, ...over,
});

test("the local day is the one in this time zone", () => {
  assert.equal(localDay(new Date(2026, 0, 5, 23, 59)), "2026-01-05");
});

test("h:mm drops the seconds and never goes negative", () => {
  assert.equal(hm(3725), "1:02");
  assert.equal(hm(59), "0:00");
  assert.equal(hm(-5), "0:00");
  assert.equal(hm(7.5 * 3600), "7:30");
});

test("a running entry counts the run in progress, a stopped one does not grow", () => {
  assert.equal(entrySeconds(entry(), NOW), 1800);
  assert.equal(entrySeconds(entry({ timerStartedOn: nowSecs - 125 }), NOW), 1925);
  assert.equal(entrySeconds(entry({ timerStartedOn: nowSecs + 60 }), NOW), 1800, "a clock behind the start adds nothing");
});

test("only today's entries are kept from the poller's three-day window", () => {
  const data = {
    entries: [
      entry({ id: 1, day: "2026-10-09" }),
      entry({ id: 2 }),
      entry({ id: 3, timerStartedOn: nowSecs - 600 }),
      entry({ id: 4, day: "2026-10-11" }),
      { broken: true },
    ],
    capacityHours: 7.5,
  };
  const day = readTimelyDay(data, NOW);
  assert.deepEqual(day.entries.map((e) => e.id), [2, 3]);
  assert.equal(day.running.id, 3);
  assert.equal(day.capacityHours, 7.5);
  assert.equal(loggedSeconds(day, NOW), 1800 + 1800 + 600);
});

test("no entries yet means no day; no capacity means none shown", () => {
  assert.equal(readTimelyDay({}, NOW), null);
  const day = readTimelyDay({ entries: [], capacityHours: 0 }, NOW);
  assert.equal(day.running, null);
  assert.equal(day.capacityHours, null);
});

test("the card shows the running timer, the day's total against capacity, and the last entries", () => {
  const today = new Date();
  const day = localDay(today);
  const secs = Math.floor(today.getTime() / 1000);
  State.integrations.integration_timely = {
    data: {
      entries: [
        entry({ id: 1, day, project: "Support", loggedSeconds: 3600 }),
        entry({ id: 2, day, project: "Website", note: "Auth refactor", loggedSeconds: 600, timerStartedOn: secs - 60 }),
      ],
      capacityHours: 7.5,
    },
    error: null, loaded: true, configured: true,
  };
  assert.ok(hasIntegrationData("integration_timely"));
  const task = { id: "integration_timely", name: "Timely", color: "#F5A524", state: "idle", steps: [], stepIndex: 0 };
  const card = renderIntegrationCard(task, {
    detailOpen: false, openDetail() {}, closeDetail() {}, openSettings() {},
  });
  const text = card.textContent;
  assert.match(text, /Timely/);
  assert.match(text, /1:11 \/ 7:30/);
  assert.match(text, /WebsiteAuth refactor0:11/);
  assert.match(text, /Support1:00/);
});

test("a project colour that is not a hex colour never reaches a row's style", () => {
  const today = new Date();
  const day = localDay(today);
  const bad = "#000;position:fixed;inset:0;opacity:0";
  State.integrations.integration_timely = {
    data: {
      entries: [
        entry({ id: 1, day, color: bad }),
        entry({ id: 2, day, color: bad, timerStartedOn: Math.floor(today.getTime() / 1000) - 60 }),
      ],
      capacityHours: null,
    },
    error: null, loaded: true, configured: true,
  };
  const task = { id: "integration_timely", name: "Timely", color: "#F5A524", state: "idle", steps: [], stepIndex: 0 };
  const card = renderIntegrationCard(task, { detailOpen: false, openDetail() {}, closeDetail() {}, openSettings() {} });
  const styles = card.find(".int-row").map((row) => row.find(".dot")[0].getAttribute("style"));
  assert.equal(styles.length, 2);
  for (const style of styles) {
    assert.ok(!style.includes("position"), style);
    assert.ok(style.includes("background:#F5A524"), style);
  }
});

test("before any data the card is the idle one", () => {
  State.integrations.integration_timely = { data: {}, error: null, loaded: false, configured: false };
  assert.equal(hasIntegrationData("integration_timely"), false);
});

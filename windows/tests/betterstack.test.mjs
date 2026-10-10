// The Better Stack card (src/views/integrations.ts). Parsing and new-incident
// detection are tested in src-tauri/src/betterstack.rs, like BetterStackTests.swift.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import { hasIntegrationData, renderIntegrationCard } from "../src/views/integrations.ts";
import { State } from "../src/core/state.ts";
import { setLanguage } from "../src/i18n/i18n.ts";

installFakeDom();

const ID = "integration_betterstack";
const task = { id: ID, name: "Better Stack", color: "#5B5FEF", state: "idle", steps: [], stepIndex: 0 };
const hooks = { detailOpen: false, openDetail() {}, closeDetail() {}, openSettings() {} };

function load(data) {
  State.integrations[ID] = { data, error: null, loaded: true, configured: true };
}

beforeEach(() => {
  setLanguage("en");
  delete State.integrations[ID];
});

test("nothing to show before the first poll", () => {
  assert.equal(hasIntegrationData(ID), false);
  load({ incidents: [], down: [] });
  assert.equal(hasIntegrationData(ID), true);
});

test("no incident and no monitor down: all monitors up", () => {
  load({ incidents: [], down: [] });
  assert.match(renderIntegrationCard(task, hooks).textContent, /Better Stack.*Incidents.*All monitors up/);
});

test("incidents first, then the down monitors no incident names, three rows at most", () => {
  load({
    incidents: [
      { id: "102", name: "shop.example.com", cause: "Timeout", startedAt: null, acknowledged: true },
      { id: "101", name: "api.example.com", cause: "Status 502", startedAt: null, acknowledged: false },
    ],
    down: [
      { id: "7", name: "api.example.com" },
      { id: "8", name: "cdn.example.com" },
      { id: "9", name: "mail.example.com" },
    ],
  });
  const card = renderIntegrationCard(task, hooks);
  const rows = card.find("BUTTON");
  assert.equal(rows.length, 3);
  assert.match(rows[0].textContent, /shop\.example\.com.*Acknowledged/);
  assert.match(rows[1].textContent, /api\.example\.com.*Status 502/);
  assert.match(rows[2].textContent, /cdn\.example\.com.*Down/);

  rows[1].fire("click");
  assert.deepEqual(sent("open_url").at(-1), { url: "https://uptime.betterstack.com/incidents/101" });
  rows[2].fire("click");
  assert.deepEqual(sent("open_url").at(-1), { url: "https://uptime.betterstack.com/monitors/8" });
});

// The Linear card (LinearCardView on macOS). Parsing, unread and snooze rules
// and the new-entry alert are tested in src-tauri/src/linear.rs, like
// LinearInboxTests.swift.

import { test } from "node:test";
import assert from "node:assert/strict";
import { calls, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();

const { State } = await import("../src/core/state.ts");
const { hasIntegrationData, linearInboxUrl, renderIntegrationCard } = await import("../src/views/integrations.ts");

const LINEAR = "integration_linear";
const hooks = { detailOpen: false, openDetail() {}, closeDetail() {}, openSettings() {} };
const task = { id: LINEAR, name: "Linear", color: "#5E6AD2", state: "idle", steps: [], stepIndex: 0 };

const note = (id, key, title) => ({
  id, reason: "mention", actor: "Ana", key, title,
  url: `https://linear.app/acme/issue/${key ?? id}`, createdAt: new Date().toISOString(),
});
const issue = (key, title) => ({
  id: key, key, title, url: `https://linear.app/acme/issue/${key}`, stateName: "In Progress",
  stateColor: "#F2C94C", updatedAt: new Date().toISOString(),
});

function load(data) {
  State.integrations[LINEAR] = { data, error: null, loaded: true, configured: true };
}

function rowTexts(card) {
  return card.find(".int-page").map((row) => row.textContent);
}

test("no data yet: the idle card, opening linear.app", () => {
  delete State.integrations[LINEAR];
  assert.equal(hasIntegrationData(LINEAR), false);
  assert.equal(linearInboxUrl(), "https://linear.app");
});

test("unread entries first, assigned issues fill the three rows", () => {
  load({
    unread: [note("n1", "ENG-12", "Fix login")],
    assigned: [issue("ENG-2", "Newer"), issue("ENG-1", "Older"), issue("ENG-0", "Oldest")],
    inboxUrl: "https://linear.app/acme/inbox",
  });
  assert.equal(hasIntegrationData(LINEAR), true);
  const card = renderIntegrationCard(task, hooks);
  const rows = rowTexts(card);
  assert.equal(rows.length, 3);
  assert.ok(rows[0].startsWith("ENG-12Fix login"));
  assert.ok(rows[1].startsWith("ENG-2Newer"));
  assert.ok(rows[2].startsWith("ENG-1Older"));
  assert.ok(card.textContent.includes("1 unread"));
  assert.equal(linearInboxUrl(), "https://linear.app/acme/inbox");
});

test("nothing unread: the subtitle says the rows are assigned issues", () => {
  load({ unread: [], assigned: [issue("ENG-2", "Newer")], inboxUrl: "https://linear.app/acme/inbox" });
  const card = renderIntegrationCard(task, hooks);
  assert.ok(card.textContent.includes("Assigned to you"));
  assert.equal(rowTexts(card).length, 1);
});

test("a project entry has no key, a row click opens its link", () => {
  load({ unread: [note("n5", null, "Q4 launch")], assigned: [], inboxUrl: "https://linear.app/acme/inbox" });
  const card = renderIntegrationCard(task, hooks);
  const [row] = card.find(".int-page");
  assert.equal(row.find(".int-key").length, 0);
  calls.length = 0;
  row.fire("click");
  assert.deepEqual(sent("open_url"), [{ url: "https://linear.app/acme/issue/n5" }]);
});

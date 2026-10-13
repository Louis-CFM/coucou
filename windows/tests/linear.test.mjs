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

test("the three newest unread entries, counted in the subtitle", () => {
  load({
    unread: [note("n1", "ENG-12", "Fix login"), note("n2", "ENG-11", "Two"), note("n3", "ENG-10", "Three"), note("n4", "ENG-9", "Four")],
    inboxUrl: "https://linear.app/acme/inbox",
  });
  assert.equal(hasIntegrationData(LINEAR), true);
  const card = renderIntegrationCard(task, hooks);
  const rows = rowTexts(card);
  assert.equal(rows.length, 3);
  assert.ok(rows[0].startsWith("ENG-12Fix login"));
  assert.ok(card.textContent.includes("4 unread"));
  assert.equal(linearInboxUrl(), "https://linear.app/acme/inbox");
});

test("nothing unread: no rows, 0 unread", () => {
  load({ unread: [], inboxUrl: "https://linear.app/acme/inbox" });
  const card = renderIntegrationCard(task, hooks);
  assert.ok(card.textContent.includes("0 unread"));
  assert.equal(rowTexts(card).length, 0);
});

test("a project entry has no key, a row click opens its link", () => {
  load({ unread: [note("n5", null, "Q4 launch")], inboxUrl: "https://linear.app/acme/inbox" });
  const card = renderIntegrationCard(task, hooks);
  const [row] = card.find(".int-page");
  assert.equal(row.find(".int-key").length, 0);
  calls.length = 0;
  row.fire("click");
  assert.deepEqual(sent("open_url"), [{ url: "https://linear.app/acme/issue/n5" }]);
});

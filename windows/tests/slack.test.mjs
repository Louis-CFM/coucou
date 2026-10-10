// The Slack card (src/views/integrations.ts). Parsing, polling and the links are
// tested in src-tauri/src/slack.rs, like SlackParsingTests.swift.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import { hasIntegrationData, renderIntegrationCard } from "../src/views/integrations.ts";
import { State } from "../src/core/state.ts";
import { lookup, setLanguage } from "../src/i18n/i18n.ts";

installFakeDom();

const SLACK = "integration_slack";
const task = { id: SLACK, name: "Slack", color: "#E01E5A", state: "idle", steps: [], stepIndex: 0, source: "n8n" };
const hooks = { detailOpen: false, openDetail() {}, closeDetail() {}, openSettings() {} };

function load(data, error = null) {
  State.integrations[SLACK] = { data, error, loaded: error == null, configured: true };
}

beforeEach(() => {
  setLanguage("en");
  delete State.integrations[SLACK];
});

test("no poll yet, or an error: the idle card", () => {
  assert.equal(hasIntegrationData(SLACK), false);
  load({}, "Missing scope: search:read");
  assert.equal(hasIntegrationData(SLACK), false);
  assert.match(renderIntegrationCard(task, hooks).textContent, /Missing scope: search:read/);
});

test("unread direct messages and mentions, with their counts", () => {
  load({
    unreadDms: 3,
    mentions: 1,
    messages: [
      { kind: "dm", channelId: "D1", author: "Alice", text: "lunch?", date: Date.now() - 120_000, unread: 3 },
      { kind: "mention", channelId: "C1", channelName: "deploys", author: "bob", text: "@me ship it",
        date: Date.now() - 600_000, permalink: "https://acme.slack.com/archives/C1/p1" },
    ],
  });
  assert.equal(hasIntegrationData(SLACK), true);
  const card = renderIntegrationCard(task, hooks);
  const text = card.textContent;
  assert.ok(text.includes("Slack") && text.includes("Messages"));
  assert.ok(text.includes("Alice") && text.includes("lunch?"));
  assert.ok(text.includes("bob · #deploys") && text.includes("@me ship it"));
  assert.ok(text.includes("3") && text.includes("@1"));

  const rows = card.find("BUTTON");
  rows[0].fire("click");
  rows[1].fire("click");
  assert.deepEqual(sent("slack_open").slice(-2), [
    { channel: "D1", permalink: null },
    { channel: "C1", permalink: "https://acme.slack.com/archives/C1/p1" },
  ]);
});

test("nothing new: says so, in the current language", () => {
  load({ unreadDms: 0, mentions: 0, messages: [] });
  assert.ok(renderIntegrationCard(task, hooks).textContent.includes("No new messages"));
  setLanguage("fr");
  const text = renderIntegrationCard(task, hooks).textContent;
  assert.ok(text.includes(lookup("No new messages", "fr")));
  assert.ok(text.includes(lookup("Messages", "fr")));
});

// The Jira card (src/views/integrations.ts). The Rust half — the account,
// mentions, comments and sprint counts — is tested in src-tauri/src/jira.rs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { calls, sent } from "./tauri.mjs";
import { State } from "../src/core/state.ts";

const JIRA = "integration_jira";
const hooks = { detailOpen: false, openDetail: () => {}, closeDetail: () => {}, openSettings: () => {} };

const comment = (id, mention) => ({
  id, key: "CC-1", summary: "Printer", author: "Ana", text: `note ${id}`, mention,
  createdAt: Date.now() - 60_000, url: `https://x.atlassian.net/browse/CC-1?focusedCommentId=${id}`,
});

async function render(data) {
  const { installFakeDom } = await import("./fakedom.mjs");
  installFakeDom();
  const { renderIntegrationCard } = await import("../src/views/integrations.ts");
  State.integrations = { [JIRA]: { configured: true, loaded: true, error: null, data } };
  return renderIntegrationCard({ id: JIRA }, hooks);
}

test("the sprint shows its progress and opens the board through the site check", async () => {
  const oldIntegrations = State.integrations;
  try {
    const card = await render({
      me: "Romain",
      sprint: { name: "Sprint 42", daysLeft: 2, todo: 1, inProgress: 1, done: 2, mineTodo: 1, mineInProgress: 0, mineDone: 1,
        url: "https://x.atlassian.net/secure/RapidBoard.jspa?rapidView=7" },
      comments: [comment("3", true), comment("2", false), comment("1", false)],
    });
    assert.match(card.textContent, /Sprint 42/);
    assert.match(card.textContent, /2\/4 done · mine 1\/2/);
    assert.match(card.textContent, /2d left/);
    // With a sprint, two comments fit; the mention leads with an @.
    const rows = card.find(".int-page");
    assert.equal(rows.length, 2);
    assert.match(rows[0].textContent, /^@CC-1 · Ana: note 3/);
    calls.length = 0;
    card.find(".jira-sprint")[0].fire("click");
    rows[1].fire("click");
    assert.deepEqual(sent("open_jira_url"), [
      { url: "https://x.atlassian.net/secure/RapidBoard.jspa?rapidView=7" },
      { url: "https://x.atlassian.net/browse/CC-1?focusedCommentId=2" },
    ]);
    assert.deepEqual(sent("open_url"), []);
  } finally {
    State.integrations = oldIntegrations;
  }
});

test("without a sprint the card lists three comments, or says there are none", async () => {
  const oldIntegrations = State.integrations;
  try {
    let card = await render({ me: "Romain", sprint: null, comments: [comment("4", false), comment("3", false), comment("2", false), comment("1", false)] });
    assert.equal(card.find(".jira-sprint").length, 0);
    assert.equal(card.find(".int-page").length, 3);
    card = await render({ me: "Romain", sprint: null, comments: [] });
    assert.match(card.textContent, /No new comments/);
  } finally {
    State.integrations = oldIntegrations;
  }
});

test("an account not loaded yet keeps the idle card", async () => {
  const { hasIntegrationData } = await import("../src/views/integrations.ts");
  const oldIntegrations = State.integrations;
  try {
    State.integrations = { [JIRA]: { configured: true, loaded: true, error: null, data: {} } };
    assert.equal(hasIntegrationData(JIRA), false);
    State.integrations = { [JIRA]: { configured: true, loaded: true, error: null, data: { me: "Romain", comments: [] } } };
    assert.equal(hasIntegrationData(JIRA), true);
  } finally {
    State.integrations = oldIntegrations;
  }
});

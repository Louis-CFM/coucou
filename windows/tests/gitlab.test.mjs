// GitLab card: its words and links (src/core/gitlab.ts), the alerts it raises
// (src/island/integrations.ts) and its lists from the keyboard (src/views/gitlab.ts).
// The Rust half — parsing and alert detection — is tested in src-tauri/src/gitlab.rs.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import { GL_STRINGS, gitlabProfileUrl, glSectionTitle, pipelinesUrl, readBaseUrl, safeGitLabUrl } from "../src/core/gitlab.ts";
import { registerIntegrationHandlers } from "../src/island/integrations.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

const GITLAB = "integration_gitlab";

test("GitLab speaks of merge requests and pipelines, the rest is GitHub's wording", () => {
  assert.equal(GL_STRINGS.title, "GitLab");
  assert.equal(glSectionTitle("myPRs"), "My MRs");
  assert.equal(glSectionTitle("mainCI"), "Default branch pipelines");
  assert.equal(glSectionTitle("toReview"), "To review");
  assert.equal(glSectionTitle("activity"), "Activity");
});

test("links open only on the configured instance", () => {
  const base = "https://git.corp.fr";
  assert.equal(safeGitLabUrl("https://git.corp.fr/a/b/-/merge_requests/1", base), "https://git.corp.fr/a/b/-/merge_requests/1");
  assert.equal(safeGitLabUrl("https://gitlab.com/a/b", base), null, "another host");
  assert.equal(safeGitLabUrl("https://git.corp.fr.evil.example/a", base), null, "look-alike host");
  assert.equal(safeGitLabUrl("javascript:alert(1)", base), null);
  assert.equal(safeGitLabUrl("file:///etc/passwd", base), null);
  assert.equal(safeGitLabUrl("not a url", base), null);
  assert.equal(safeGitLabUrl("https://git.corp.fr/x", "not a url"), null);
  assert.equal(safeGitLabUrl("https://git.corp.fr:8443/x", base), null, "another port is another host");
});

test("pipelines and profile links", () => {
  assert.equal(pipelinesUrl("https://gitlab.com/me/app"), "https://gitlab.com/me/app/-/pipelines");
  assert.equal(pipelinesUrl("https://gitlab.com/me/app/"), "https://gitlab.com/me/app/-/pipelines");
  assert.equal(gitlabProfileUrl("https://git.corp.fr/", "jo hn"), "https://git.corp.fr/jo%20hn");
});

test("the instance comes from what Rust sent, gitlab.com before the first answer", () => {
  assert.equal(readBaseUrl({}), "https://gitlab.com");
  assert.equal(readBaseUrl({ baseUrl: "" }), "https://gitlab.com");
  assert.equal(readBaseUrl({ baseUrl: "https://git.corp.fr" }), "https://git.corp.fr");
});

const island = { reveal: () => {} };
registerIntegrationHandlers(island);

const gitlab = () => State.tasks.find((t) => t.id === GITLAB);

beforeEach(() => {
  calls.length = 0;
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.paused = false;
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: ["integration_github", GITLAB] };
  State.loadIntegrationTasks();
});

test("a GitLab alert badges the GitLab pill and not GitHub's", () => {
  emit("gitlab-alerts", [{ kind: "ciFailed", prId: "g/p!1" }]);
  assert.equal(gitlab().pillBadge, "error");
  assert.equal(State.tasks.find((t) => t.id === "integration_github").pillBadge ?? null, null);
  emit("github-alerts", [{ kind: "ciPassed", prId: "a/b#1" }]);
  assert.equal(gitlab().pillBadge, "error", "a GitHub alert leaves it alone");
});

test("no badge while the GitLab pill is on screen, none while paused", () => {
  State.setFocus(GITLAB);
  emit("gitlab-alerts", [{ kind: "reviewRequested", prId: "g/p!2" }]);
  assert.equal(gitlab().pillBadge ?? null, null);
  State.setFocus("integration_claude");
  State.paused = true;
  emit("gitlab-alerts", [{ kind: "mainFailed", repo: "g/p" }]);
  assert.equal(gitlab().pillBadge ?? null, null);
});

test("showing the GitLab card asks Rust for a GitLab refresh, once per showing", () => {
  State.setFocus(GITLAB);
  State.mode = "expanded";
  State.notify();
  State.notify();
  assert.deepEqual(sent("gitlab_refresh"), [{ section: "pulse" }]);
  assert.deepEqual(sent("github_refresh"), []);
});

test("Ctrl+O on a GitLab row opens it only on the configured instance", async () => {
  const { installFakeDom } = await import("./fakedom.mjs");
  installFakeDom();
  const { highlightRow, listRows, openRow } = await import("../src/views/github.ts");
  const { gitlabDetail, gitlabPulseCard } = await import("../src/views/gitlab.ts");
  const base = "https://git.corp.fr";
  const mr = (n, url) => ({
    id: `me/app!${n}`, title: `MR ${n}`, url, repo: "me/app", number: n, isDraft: false,
    ci: "success", review: "unknown", headSha: null,
  });
  const pulse = {
    login: "me", fetchedAt: 1, toReview: [], mainCI: [],
    myPRs: [
      mr(1, `${base}/me/app/-/merge_requests/1`),
      mr(2, "https://evil.example/2"),
      mr(3, `${base}/me/app/-/merge_requests/3`),
    ],
  };
  assert.deepEqual(listRows(gitlabPulseCard(pulse, null, null, () => {})), []);

  const rows = listRows(gitlabDetail(pulse, null, null, base, () => {}));
  assert.equal(rows.length, 3);
  highlightRow(rows, 1, true);
  assert.deepEqual(rows.map((r) => r.classList.contains("selected")), [false, true, false]);

  calls.length = 0;
  openRow(rows[0]);
  assert.deepEqual(sent("open_url"), [{ url: `${base}/me/app/-/merge_requests/1` }]);
  openRow(rows[1]);
  assert.equal(sent("open_url").length, 1, "another host does not open");
});

test("a thread waiting for you rings like a review request", async () => {
  const { gitHubAlert } = await import("../src/core/github.ts");
  assert.deepEqual(gitHubAlert([{ kind: "commentPending", threadId: "a" }]), { badge: "finished", sound: "question" });
  assert.deepEqual(
    gitHubAlert([{ kind: "commentPending", threadId: "a" }, { kind: "ciFailed", prId: "g/p!1" }]),
    { badge: "error", sound: "error" },
    "a red pipeline is still louder",
  );
  State.setFocus("integration_claude");
  emit("gitlab-alerts", [{ kind: "commentPending", threadId: "a" }]);
  assert.equal(gitlab().pillBadge, "finished");
});

test("the card's button opens the merge request panel", async () => {
  const { installFakeDom } = await import("./fakedom.mjs");
  installFakeDom();
  const { gitlabPulseCard } = await import("../src/views/gitlab.ts");
  const pulse = { login: "me", fetchedAt: 1, toReview: [], mainCI: [], myPRs: [] };
  const card = gitlabPulseCard(pulse, null, null, () => {});
  const button = card.find(".gl-expand")[0];
  assert.ok(button, "the card has the button");
  calls.length = 0;
  button.fire("click");
  assert.equal(sent("gitlab_panel_toggle").length, 1);
});

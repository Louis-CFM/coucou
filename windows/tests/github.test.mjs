// GitHub pulse, alerts and contribution grid (src/core/github.ts and the alert
// handling in src/island/integrations.ts). The Rust half — parsing and alert
// detection — is tested in src-tauri/src/github.rs, like GitHubPulseTests.swift.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import {
  GRID_WEEKS, activityHeader, actionsUrl, ciWord, contributionColor, contributionsLabel, dayLabel,
  formatCount, gitHubAlert, lastDays, lastWeeks, mainCISummary, myPRsValue, profileUrl, readActivity,
  readPulse, readStats, safeGitHubUrl, shortRepo, totalLabel, weekColumn, worstCI,
} from "../src/core/github.ts";
import { registerIntegrationHandlers } from "../src/island/integrations.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

const GITHUB = "integration_github";

// ── Fixtures (GitHubActivityTests.swift) ──────────────────────────────────────

const day = (date, count, level, weekday) => ({ date, count, level, weekday });
const activity = {
  total: 42,
  fetchedAt: 0,
  weeks: [
    [
      day("2026-01-05", 0, 0, 0), day("2026-01-06", 1, 1, 1), day("2026-01-07", 4, 2, 2),
      day("2026-01-08", 8, 3, 3), day("2026-01-09", 12, 4, 4), day("2026-01-10", 2, 1, 5),
      day("2026-01-11", 0, 0, 6),
    ],
    [day("2026-01-12", 5, 2, 0), day("2026-01-13", 10, 3, 1)],
  ],
};

const pr = (id, ci) => ({
  id, title: "T", url: `https://github.com/${id.replace("#", "/pull/")}`, repo: id.split("#")[0],
  number: Number(id.split("#")[1]), isDraft: false, ci, review: "unknown", headSha: null,
});
const repo = (name, ci) => ({ repo: name, url: `https://github.com/${name}`, branch: "main", ci, headSha: null });

// ── Contribution grid ─────────────────────────────────────────────────────────

test("lastWeeks returns the newest weeks, oldest first, clamped", () => {
  assert.equal(lastWeeks(activity, 2).length, 2);
  assert.equal(lastWeeks(activity, 1).length, 1);
  assert.equal(lastWeeks(activity, 1)[0].length, 2, "the current week is incomplete");
  assert.equal(lastWeeks(activity, 1)[0][0].date, "2026-01-12");
  assert.equal(lastWeeks(activity, 99).length, 2);
  assert.deepEqual(lastWeeks(activity, 0), []);
});

test("lastDays returns the newest days across weeks, oldest first, clamped", () => {
  assert.deepEqual(lastDays(activity, 3).map((d) => d.date), ["2026-01-11", "2026-01-12", "2026-01-13"]);
  assert.equal(lastDays(activity, 9).length, 9);
  assert.equal(lastDays(activity, 99).length, 9);
  assert.deepEqual(lastDays(activity, 0), []);
});

test("the grid shows 23 weeks, Sunday on top, gaps where a day is missing", () => {
  assert.equal(GRID_WEEKS, 23);
  const column = weekColumn(activity.weeks[1]);
  assert.equal(column.length, 7);
  assert.equal(column[0].date, "2026-01-12");
  assert.equal(column[1].date, "2026-01-13");
  assert.deepEqual(column.slice(2), [null, null, null, null, null]);
  assert.deepEqual(weekColumn([day("2026-01-14", 1, 1, 3)]).map((d) => d?.weekday ?? null),
    [null, null, null, 3, null, null, null]);
});

test("contribution levels map to GitHub's greens", () => {
  assert.equal(contributionColor(0), "rgba(255,255,255,0.06)");
  assert.equal(contributionColor(1), "#0E4429");
  assert.equal(contributionColor(4), "#39D353");
  assert.equal(contributionColor(9), "rgba(255,255,255,0.06)");
});

test("a picked day shows its date and count, otherwise the year", () => {
  assert.equal(dayLabel("2026-01-05"), "Jan 5");
  assert.equal(dayLabel("2026-12-31"), "Dec 31");
  assert.equal(dayLabel("garbage"), "garbage");
  assert.equal(dayLabel("2026-13-01"), "2026-13-01");
  assert.equal(contributionsLabel(0), "No contributions");
  assert.equal(contributionsLabel(1), "1 contribution");
  assert.equal(contributionsLabel(12), "12 contributions");
  assert.equal(totalLabel(1234), "1,234");
  const stats = { totalRepos: 8, totalStars: 3 };
  assert.equal(activityHeader(activity, stats, activity.weeks[0][4]), "Jan 9 · 12 contributions");
  assert.equal(activityHeader(activity, stats, null), "42 past year · 8 repos");
  assert.equal(activityHeader(activity, null, null), "42 past year");
  assert.equal(activityHeader(null, stats, null), "");
});

// ── Card summaries ────────────────────────────────────────────────────────────

test("the worst CI wins: failure, then pending, then success", () => {
  assert.equal(worstCI([]), "unknown");
  assert.equal(worstCI(["success", "unknown"]), "success");
  assert.equal(worstCI(["success", "pending"]), "pending");
  assert.equal(worstCI(["pending", "failure", "success"]), "failure");
});

test("My PRs counts, then says how many fail or that some still run", () => {
  assert.equal(myPRsValue([]), "0");
  assert.equal(myPRsValue([pr("a/b#1", "success"), pr("a/b#2", "unknown")]), "2");
  assert.equal(myPRsValue([pr("a/b#1", "success"), pr("a/b#2", "pending")]), "2 · running");
  assert.equal(myPRsValue([pr("a/b#1", "failure"), pr("a/b#2", "pending")]), "2 · 1 failing");
});

test("default branch CI sums up the recent repos", () => {
  assert.deepEqual(mainCISummary([]), { failing: false, color: "#6B7079", value: "no repos" });
  assert.deepEqual(mainCISummary([repo("a/b", "unknown")]), { failing: false, color: "#6B7079", value: "unknown" });
  assert.deepEqual(mainCISummary([repo("a/b", "success")]), { failing: false, color: "#22C55E", value: "all green" });
  assert.deepEqual(mainCISummary([repo("a/b", "success"), repo("a/c", "pending")]),
    { failing: false, color: "#F5A524", value: "running" });
  assert.deepEqual(mainCISummary([repo("a/b", "failure"), repo("a/c", "failure"), repo("a/d", "pending")]),
    { failing: true, color: "#F4505E", value: "2 failing" });
  assert.equal(ciWord("success"), "passing");
  assert.equal(ciWord("unknown"), null);
});

test("small formatting helpers", () => {
  assert.equal(formatCount(999), "999");
  assert.equal(formatCount(1234), "1.2k");
  assert.equal(shortRepo("owner/repo"), "repo");
  assert.equal(shortRepo("repo"), "repo");
});

// ── Links ─────────────────────────────────────────────────────────────────────

test("only http(s) links to github.com open", () => {
  assert.equal(safeGitHubUrl("https://github.com/a/b/pull/1"), "https://github.com/a/b/pull/1");
  assert.equal(safeGitHubUrl("http://github.com/a"), "http://github.com/a");
  assert.equal(safeGitHubUrl("javascript:alert(1)"), null);
  assert.equal(safeGitHubUrl("file:///etc/passwd"), null);
  assert.equal(safeGitHubUrl("https://github.com.evil.example/a"), null);
  assert.equal(safeGitHubUrl("https://evil.example/?github.com"), null);
  assert.equal(safeGitHubUrl("not a url"), null);
  assert.equal(actionsUrl("https://github.com/a/b"), "https://github.com/a/b/actions");
  assert.equal(actionsUrl("https://github.com/a/b/"), "https://github.com/a/b/actions");
  assert.equal(profileUrl("octo cat"), "https://github.com/octo%20cat");
});

// ── Reading what Rust sends ───────────────────────────────────────────────────

test("card data is read defensively", () => {
  assert.equal(readPulse({}), null);
  assert.equal(readPulse({ pulse: { myPRs: [] } }), null);
  const pulse = { login: "me", myPRs: [], toReview: [], mainCI: [], fetchedAt: 1 };
  assert.equal(readPulse({ pulse }), pulse);
  assert.equal(readActivity({ activity: { weeks: "x", total: 1 } }), null);
  assert.equal(readActivity({ activity }), activity);
  assert.equal(readStats({}), null);
  assert.deepEqual(readStats({ totalRepos: 3, totalStars: 10 }), { totalRepos: 3, totalStars: 10 });
});

// ── Alerts (AppState.handleGitHubEvents) ──────────────────────────────────────

test("the loudest event decides the badge and the sound", () => {
  assert.equal(gitHubAlert([]), null);
  assert.deepEqual(gitHubAlert([{ kind: "ciPassed", prId: "a" }]), { badge: "finished", sound: "finish" });
  assert.deepEqual(gitHubAlert([{ kind: "ciPassed", prId: "a" }, { kind: "reviewRequested", prId: "b" }]),
    { badge: "finished", sound: "question" });
  assert.deepEqual(
    gitHubAlert([{ kind: "reviewRequested", prId: "b" }, { kind: "mainFailed", repo: "r" }, { kind: "ciPassed", prId: "a" }]),
    { badge: "error", sound: "error" },
  );
  assert.deepEqual(gitHubAlert([{ kind: "ciFailed", prId: "a" }]), { badge: "error", sound: "error" });
});

const island = { reveal: () => {} };
registerIntegrationHandlers(island);

const github = () => State.tasks.find((t) => t.id === GITHUB);

beforeEach(() => {
  calls.length = 0;
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.paused = false;
  State.settings = { ...DEFAULT_SETTINGS };
  State.loadIntegrationTasks();
});

test("an alert badges the GitHub pill when another pill is on screen", () => {
  emit("github-alerts", [{ kind: "mainFailed", repo: "a/b" }]);
  assert.equal(github().pillBadge, "error");
  assert.equal(github().state, "idle", "Nova's state is left alone, as on macOS");
});

test("no badge while the GitHub pill is the one on screen", () => {
  State.setFocus(GITHUB);
  emit("github-alerts", [{ kind: "reviewRequested", prId: "a/b#1" }]);
  assert.equal(github().pillBadge, null);
});

test("nothing happens while paused", () => {
  State.paused = true;
  emit("github-alerts", [{ kind: "ciFailed", prId: "a/b#1" }]);
  assert.equal(github().pillBadge ?? null, null);
});

test("showing the GitHub card asks Rust for a refresh, once per showing", () => {
  State.setFocus(GITHUB);
  assert.deepEqual(sent("github_refresh"), [], "not while the island is closed");
  State.mode = "expanded";
  State.notify();
  State.notify();
  assert.deepEqual(sent("github_refresh"), [{ section: "pulse" }]);
  State.setFocus("integration_claude");
  State.setFocus(GITHUB);
  assert.deepEqual(sent("github_refresh"), [{ section: "pulse" }, { section: "pulse" }]);
});

// ── The lists from the keyboard (GitHubDetailView: ⌘↓ ⌘↑ ⌘O) ──────────────────

test("Ctrl+↓ ↑ highlight a list row, Ctrl+O does what its click does", async () => {
  const { installFakeDom } = await import("./fakedom.mjs");
  installFakeDom();
  const { githubDetail, githubPulseCard, highlightRow, listRows, openRow } = await import("../src/views/github.ts");
  const pr = (n, url) => ({
    id: `me/app#${n}`, title: `PR ${n}`, url, repo: "me/app", number: n, isDraft: false,
    ci: "success", review: "none", headSha: null,
  });
  const pulse = {
    login: "me", fetchedAt: 1, toReview: [], mainCI: [],
    myPRs: [
      pr(1, "https://github.com/me/app/pull/1"),
      pr(2, "https://evil.example/2"),
      pr(3, "https://github.com/me/app/pull/3"),
    ],
  };
  // The summary card has no list to walk.
  assert.deepEqual(listRows(githubPulseCard(pulse, null, null, () => {})), []);

  const rows = listRows(githubDetail(pulse, null, null, () => {}));
  assert.equal(rows.length, 3);
  highlightRow(rows, 1, true);
  assert.deepEqual(rows.map((r) => r.classList.contains("selected")), [false, true, false]);
  highlightRow(rows, null, false);
  assert.ok(rows.every((r) => !r.classList.contains("selected")));

  calls.length = 0;
  openRow(rows[0]);
  assert.deepEqual(sent("open_url"), [{ url: "https://github.com/me/app/pull/1" }]);
  // The same check as a click: only github.com opens.
  openRow(rows[1]);
  openRow(undefined);
  assert.equal(sent("open_url").length, 1);
});

// Dev harness: the real island with made-up GitHub data, in a plain browser, so
// the card and the panel can be looked at without a token or the Rust side.
// Not part of the app bundle. `npm run dev`, then /dev/github-preview.html.

import "../src/style.css";
import {
  Bridge, type GithubActivity, type GithubBuild, type GithubCommentsDetail, type GithubData, type GithubDay,
  type GithubDetail, type GithubFile, type GithubJob, type GithubProject, type GithubPullDetail, type GithubRemark,
  type GithubRepo, type GithubRunDetail, type GithubStep, type GithubTarget,
} from "../src/core/bridge";
import { State } from "../src/core/state";
import { Island } from "../src/island/island";

const params = new URLSearchParams(location.search);
const minutesAgo = (m: number) => new Date(Date.now() - m * 60_000).toISOString();

const pullTarget = (repo: string, number: number): GithubTarget => ({ kind: "pull", repo, number });
const pushTarget = (repo: string, count: number, branch: string): GithubTarget => ({
  kind: "commits", repo, head: "a1b2c3d4e5f6", count, branch, author: null, from: null, to: null,
});

const activity: GithubActivity[] = [
  { kind: "pr_merged", repo: "mochi/coucou", title: "GitHub panel for the Windows island", detail: "#12", url: "https://github.com", at: minutesAgo(4), target: pullTarget("mochi/coucou", 12) },
  { kind: "push", repo: "mochi/coucou", title: "Keep the last snapshot through an error", detail: "3 commits · windows-github-panel", url: "https://github.com", at: minutesAgo(38), target: pushTarget("mochi/coucou", 3, "windows-github-panel") },
  { kind: "pr_opened", repo: "mochi/coucou", title: "Windows: GitHub panel", detail: "#12", url: "https://github.com", at: minutesAgo(95), target: pullTarget("mochi/coucou", 12) },
  { kind: "issue_opened", repo: "louis-cfm/coucou", title: "Defender flags the installer", detail: "#9", url: "https://github.com", at: minutesAgo(60 * 5), target: { kind: "issue", repo: "louis-cfm/coucou", number: 9 } },
  { kind: "release", repo: "mochi/tour-convention-geneve", title: "Sprint 3", detail: "v0.3.0", url: "https://github.com", at: minutesAgo(60 * 26), target: { kind: "release", repo: "mochi/tour-convention-geneve", tag: "v0.3.0" } },
  { kind: "issue_closed", repo: "mochi/tour-convention-geneve", title: "Map tiles flicker on zoom", detail: "#41", url: "https://github.com", at: minutesAgo(60 * 50), target: { kind: "issue", repo: "mochi/tour-convention-geneve", number: 41 } },
  { kind: "pr_closed", repo: "mochi/dotfiles", title: "Try another prompt theme", detail: "#3", url: "https://github.com", at: minutesAgo(60 * 72), target: pullTarget("mochi/dotfiles", 3) },
  { kind: "create", repo: "mochi/sandbox", title: "Created the repository", detail: null, url: "https://github.com", at: minutesAgo(60 * 24 * 6), target: { kind: "project", repo: "mochi/sandbox" } },
  { kind: "push", repo: "mochi/sandbox", title: "Pushed", detail: "main", url: "https://github.com", at: minutesAgo(60 * 24 * 6), target: pushTarget("mochi/sandbox", 1, "main") },
];

// The sheets behind those lines, one per kind, with a real-looking diff.
const PATCH = [
  "@@ -12,9 +12,14 @@ export function enterGithubPanel() {",
  "   sweepNext = true;",
  "-  if (sheet) closeSheet();",
  "-  else touchSheet();",
  "+  if (day) stopSearching(day);",
  "+  day = null;",
  "+  clearStack();",
  "+  touch();",
  "   const d = githubData();",
  "   if (!d || Date.now() - d.fetchedAt > STALE_MS) void Bridge.refreshIntegration(ID);",
  " }",
  "@@ -40,6 +45,8 @@ function eventRow(",
  "   const style = ACTIVITY_STYLE[item.kind];",
  "+  // A line of activity opens its sheet; GitHub is the last resort.",
  "+  const open = () => openTarget(item.target, item.title, item.url);",
  "   return h(",
  "\\ No newline at end of file",
].join("\n");
const files: GithubFile[] = [
  { path: "windows/src/views/github.ts", status: "modified", additions: 612, deletions: 58, patch: PATCH, truncated: true },
  { path: "windows/src-tauri/src/github_detail.rs", status: "added", additions: 540, deletions: 0, patch: PATCH, truncated: false },
  { path: "windows/src/style.css", status: "modified", additions: 180, deletions: 6, patch: PATCH, truncated: false },
  { path: "windows/screenshots/panel.png", status: "added", additions: 0, deletions: 0, patch: null, truncated: false },
];
const ci = (state: "success" | "failure" | "running" | "neutral"): GithubBuild => ({
  id: 1, state, workflow: "CI", branch: "windows-github-panel", url: "https://github.com", at: minutesAgo(6),
});
// A run with its jobs side by side; `running` catches it halfway.
const live = params.has("running");
const runStart = Date.now() - (live ? 100 : 7 * 60) * 1000;
const t = (s: number) => new Date(runStart + s * 1000).toISOString();
const step = (name: string, from: number, to: number | null, outcome = "passed"): GithubStep => ({
  name, outcome,
  state: outcome === "failed" ? "failure" : outcome === "skipped" ? "neutral" : to == null ? "running" : "success",
  startedAt: outcome === "skipped" ? null : t(from), endedAt: to == null ? null : t(to),
});
const jobs: GithubJob[] = [
  {
    id: 1, name: "lint", state: "success", outcome: "passed", url: "https://github.com", runner: "ubuntu-latest",
    startedAt: t(4), endedAt: t(46),
    steps: [step("Set up job", 4, 6), step("Checkout", 6, 8), step("npm ci", 8, 31), step("Type-check", 31, 45), step("Complete job", 45, 46)],
  },
  {
    id: 2, name: "build (windows)", state: live ? "running" : "success", outcome: live ? "running" : "passed",
    url: "https://github.com", runner: "windows-latest", startedAt: t(5), endedAt: live ? null : t(212),
    steps: [
      step("Set up job", 5, 9), step("Checkout", 9, 12), step("Set up Rust", 12, 41), step("Restore cache", 41, 52),
      live ? step("cargo build --release", 52, null) : step("cargo build --release", 52, 198),
      ...(live ? [] : [step("Save cache", 198, 210), step("Complete job", 210, 212)]),
    ],
  },
  {
    id: 3, name: "test", state: live ? "running" : "failure", outcome: live ? "running" : "failed",
    url: "https://github.com", runner: "ubuntu-latest", startedAt: t(5), endedAt: live ? null : t(141),
    steps: [
      step("Set up job", 5, 7), step("Checkout", 7, 9), step("Set up Rust", 9, 35),
      live ? step("cargo test", 35, null) : step("cargo test", 35, 139, "failed"),
      ...(live ? [] : [step("Upload report", 139, 139, "skipped"), step("Complete job", 139, 141)]),
    ],
  },
  {
    id: 4, name: "deploy", state: live ? "running" : "neutral", outcome: live ? "queued" : "skipped",
    url: "https://github.com", runner: null, startedAt: null, endedAt: null, steps: [],
  },
];
const runDetail: GithubRunDetail = {
  kind: "run", repo: "mochi/coucou", id: 1, workflow: "CI", title: "Keep the last snapshot through an error",
  branch: "windows-github-panel", event: "push", actor: "mochi", attempt: 1, url: "https://github.com",
  state: live ? "running" : "failure", outcome: live ? "running" : "failed",
  startedAt: t(0), endedAt: live ? null : t(212), jobs, moreJobs: 0,
};

// `running=play`: a run that goes on while you watch, over some fifty seconds
// from the moment the page opened — lint passes, then test (or breaks, with
// `fail`), then build, then deploy wakes up and ships. Every answer is the
// run as it would stand at that moment, so the panel's own refresh sees it
// move: what its jobs' Mochis and the big one do can be watched to the end.
const played = params.get("running") === "play";
const opened = Date.now();

function playedRun(): GithubRunDetail {
  const elapsed = (Date.now() - opened) / 1000;
  const at = (s: number) => new Date(opened + s * 1000).toISOString();
  const breaks = params.has("fail");
  // from / to: seconds from the opening; a step's number is where in its job it ends.
  const plans: { id: number; name: string; runner: string; from: number; to: number; ends: "passed" | "failed" | "skipped"; steps: [string, number][] }[] = [
    { id: 1, name: "lint", runner: "ubuntu-latest", from: -16, to: 14, ends: "passed", steps: [["Set up job", 0.1], ["Checkout", 0.2], ["npm ci", 0.7], ["Type-check", 1]] },
    { id: 2, name: "build (windows)", runner: "windows-latest", from: -15, to: 34, ends: "passed", steps: [["Set up job", 0.1], ["Set up Rust", 0.3], ["cargo build --release", 0.95], ["Save cache", 1]] },
    { id: 3, name: "test", runner: "ubuntu-latest", from: -15, to: 24, ends: breaks ? "failed" : "passed", steps: [["Set up job", 0.1], ["Set up Rust", 0.4], ["cargo test", 1]] },
    { id: 4, name: "deploy", runner: "ubuntu-latest", from: 34, to: 46, ends: breaks ? "skipped" : "passed", steps: [["Set up job", 0.2], ["Upload", 1]] },
  ];
  const jobs: GithubJob[] = plans.map((p) => {
    const waiting = elapsed < p.from;
    const skipped = p.ends === "skipped" && !waiting;
    const done = elapsed >= p.to;
    const length = p.to - p.from;
    let before = 0;
    const steps: GithubStep[] = waiting || skipped ? [] : p.steps.map(([name, end], i) => {
      const from = p.from + before * length;
      const to = p.from + end * length;
      before = end;
      const broke = p.ends === "failed" && done && i === p.steps.length - 1;
      const over = elapsed >= to;
      return {
        name,
        state: broke ? "failure" : over ? "success" : "running",
        outcome: broke ? "failed" : over ? "passed" : elapsed >= from ? "running" : "queued",
        startedAt: elapsed >= from ? at(from) : null, endedAt: over ? at(to) : null,
      };
    });
    return {
      id: p.id, name: p.name, url: "https://github.com", runner: p.runner, steps,
      state: skipped ? "neutral" : !done ? "running" : p.ends === "failed" ? "failure" : "success",
      outcome: skipped ? "skipped" : waiting ? "queued" : !done ? "running" : p.ends,
      startedAt: waiting || skipped ? null : at(p.from), endedAt: done && !skipped ? at(p.to) : null,
    };
  });
  const over = jobs.every((j) => j.state !== "running");
  const broke = jobs.some((j) => j.state === "failure");
  return {
    ...runDetail, jobs,
    state: !over ? "running" : broke ? "failure" : "success",
    outcome: !over ? "running" : broke ? "failed" : "passed",
    startedAt: at(-16), endedAt: over ? at(breaks ? 34 : 46) : null,
  };
}

// What was said on the pull request: a description, a thread still open on a
// line of the first file's diff, a review asking for changes, a thread settled,
// one on code that has changed since, an answer, an approval.
const said = (author: string | null, minutes: number, body: string, cut = false): GithubRemark => ({
  author, body, cut, at: minutesAgo(minutes), url: "https://github.com",
});
const comments: GithubCommentsDetail = {
  kind: "comments", repo: "mochi/coucou", number: 12, title: "GitHub panel for the Windows island", url: "https://github.com",
  earlier: params.has("earlier"),
  entries: params.has("quiet") ? [] : [
    { kind: "description", ...said("mochi", 60 * 50, "Turns the GitHub pill into a panel: the year's activity, each project's sheet, and the sheet behind every line.\n\nEverything is fetched on the click, by the Rust side, with a read-only token.") },
    {
      kind: "thread", path: "windows/src/views/github.ts", line: 16, side: "right", resolved: false, outdated: false, more: 0,
      code: [
        { number: 13, sign: "+", text: "  if (day) stopSearching(day);" },
        { number: 14, sign: "+", text: "  day = null;" },
        { number: 15, sign: "+", text: "  clearStack();" },
        { number: 16, sign: "+", text: "  touch();" },
      ],
      remarks: [
        said("louis", 60 * 30, "Is this touch() needed? clearStack() already drops the sheets."),
        said("mochi", 60 * 29, "It is: the view only redraws when its key changes, and a sheet dropped without a new stamp stayed on screen."),
      ],
    },
    { kind: "review", state: "changes requested", ...said("louis", 60 * 28, "Nearly there. Two things on the code, and the panel should not poll while the island is hidden.") },
    {
      kind: "thread", path: "windows/src/style.css", line: 46, side: "right", resolved: true, outdated: false, more: 2,
      code: [{ number: 46, sign: "+", text: "  // A line of activity opens its sheet; GitHub is the last resort." }],
      remarks: [said("kirzen", 60 * 27, "Typo."), said("mochi", 60 * 26, "Fixed.")],
    },
    {
      kind: "thread", path: "windows/src-tauri/src/github_detail.rs", line: null, side: "right", resolved: false, outdated: true, more: 0,
      code: [
        { number: 286, sign: "", text: "    if !force {" },
        { number: 287, sign: "-", text: "        if let Some(cached) = CACHE.get(&key) {" },
        { number: 287, sign: "+", text: "        if let Some((at, cached)) = CACHE.lock().unwrap().get(&key) {" },
      ],
      remarks: [said("louis", 60 * 26, "A minute of cache is fine here, but say so where the constant is.")],
    },
    { kind: "comment", ...said("mochi", 60 * 20, "Both fixed, and nothing is fetched on a timer any more: the sheets load on the click only.\n\nThe run under a pull request is the one exception, and only while the panel is open.") },
    { kind: "comment", ...said(null, 60 * 12, "A very long comment, cut short by Coucou so the panel stays a panel…", true) },
    { kind: "review", state: "approved", ...said("louis", 9, "") },
  ],
};

const details: Record<GithubTarget["kind"], GithubDetail> = {
  run: runDetail,
  comments,
  pull: {
    kind: "pull", repo: "mochi/coucou", number: 12, title: "GitHub panel for the Windows island", url: "https://github.com",
    state: "merged", author: "mochi", base: "main", head: "windows-github-panel",
    additions: 1332, deletions: 64, changedFiles: 14, commits: 18,
    comments: params.has("quiet") ? 0 : 3, threads: params.has("quiet") ? 0 : 3, review: "approved",
    reviewers: [{ login: "louis", state: "approved" }, { login: "kirzen", state: "commented" }],
    labels: [{ name: "windows", color: "#0e8a16" }, { name: "enhancement", color: "#a2eeef" }],
    files, createdAt: minutesAgo(60 * 50), mergedAt: minutesAgo(4), mergedBy: "louis", closedAt: minutesAgo(4),
    ci: ci(params.has("running") ? "running" : "success"), missing: [],
  },
  issue: {
    kind: "issue", repo: "louis-cfm/coucou", number: 9, title: "Defender flags the installer", url: "https://github.com",
    state: "open", author: "mochi", comments: 4, assignees: ["louis"],
    body: "Windows Defender reports Trojan:Win32/Wacatac.H!ml on the unsigned installer. It's a machine-learning false positive; a report is under review.",
    labels: [{ name: "windows", color: "#0e8a16" }, { name: "bug", color: "#d73a4a" }],
    createdAt: minutesAgo(60 * 5), closedAt: null,
  },
  commits: {
    kind: "commits", repo: "mochi/coucou", branch: "windows-github-panel", total: 3,
    commits: [
      { sha: "a1b2c3d", id: "a1b2c3d4e5f6", message: "Keep the last snapshot through an error", author: "mochi", at: minutesAgo(38), url: "https://github.com" },
      { sha: "9f8e7d6", id: "9f8e7d6c5b4a", message: "Fade the list only while there is more", author: "mochi", at: minutesAgo(52), url: "https://github.com" },
      { sha: "5a4b3c2", id: "5a4b3c2d1e0f", message: "Close the sheet when the panel reopens", author: "mochi", at: minutesAgo(70), url: "https://github.com" },
    ],
    additions: 22, deletions: 4, files: files.slice(0, 2), ci: ci("failure"), url: "https://github.com", missing: [],
  },
  release: {
    kind: "release", repo: "mochi/tour-convention-geneve", tag: "v0.3.0", name: "Sprint 3", url: "https://github.com",
    body: "What's new: the interactive map, the torch relay journal, and the partner pages.", author: "mochi",
    publishedAt: minutesAgo(60 * 26), prerelease: false, downloads: 1284,
    assets: [{ name: "site-build.zip", downloads: 1200, size: 18_400_000 }, { name: "checksums.txt", downloads: 84, size: 512 }],
  },
  project: { kind: "locked", permission: "Contents" },
};
Bridge.githubDetail = async (target) => {
  await new Promise((r) => setTimeout(r, 700));
  if (params.has("locked")) return { kind: "locked", permission: "Contents" };
  if (played && target.kind === "run") return playedRun();
  if (played && target.kind === "pull") {
    return { ...(details.pull as GithubPullDetail), ci: ci(playedRun().state) };
  }
  return details[target.kind];
};

const repo = (
  name: string, language: [string, string] | null, stars: number, openPrs: number,
  build: GithubRepo["build"], pushedMinutesAgo: number, priv = false,
): GithubRepo => ({
  fullName: `mochi/${name}`, url: "https://github.com", private: priv,
  language: language?.[0] ?? null, languageColor: language?.[1] ?? null,
  stars, openPrs, pushedAt: minutesAgo(pushedMinutesAgo), build,
});
const run = (state: "success" | "failure" | "running" | "neutral", m: number) => ({
  id: m, state, workflow: "CI", branch: "main", url: "https://github.com", at: minutesAgo(m),
});

const repos: GithubRepo[] = [
  // A project you contribute to without owning it: shown with its owner.
  { ...repo("coucou", ["Swift", "#F05138"], 1204, 3, run("success", 20), 2), fullName: "louis-cfm/coucou" },
  repo("coucou", ["Rust", "#dea584"], 4, 2, run("running", 1), 4),
  repo("tour-convention-geneve", ["TypeScript", "#3178c6"], 38, 5, run("failure", 50), 50),
  repo("dotfiles", ["Shell", "#89e051"], 12, 0, run("success", 60 * 26), 60 * 26),
  repo("notes", null, 0, 0, null, 60 * 30, true),
  repo("sandbox", ["Python", "#3572A5"], 3, 1, run("neutral", 60 * 24 * 6), 60 * 24 * 6),
  repo("portfolio", ["Astro", "#ff5a03"], 27, 0, run("success", 60 * 24 * 9), 60 * 24 * 9),
];

// A plausible year: quiet weekends, a few busy stretches, a streak up to today.
// Seeded, so every reload draws the same graph.
const today = new Date();
const todayUtc = Date.UTC(today.getFullYear(), today.getMonth(), today.getDate());
const firstSunday = todayUtc - (new Date(todayUtc).getUTCDay() + 52 * 7) * 86_400_000;
const days = Math.round((todayUtc - firstSunday) / 86_400_000) + 1;
let seed = 7;
const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
const counts = Array.from({ length: days }, (_, i) => {
  const weekday = new Date(firstSunday + i * 86_400_000).getUTCDay();
  const busy = Math.sin(i / 23) > 0.3 ? 2.2 : 1;
  const base = weekday === 0 || weekday === 6 ? 0.25 : 1;
  const n = Math.floor(rand() * 6 * busy * base - (rand() < 0.35 ? 3 : 0));
  return i >= days - 6 ? Math.max(1, n) : Math.max(0, n);
});
const level = (n: number) => (n === 0 ? 0 : n <= 2 ? 1 : n <= 5 ? 2 : n <= 8 ? 3 : 4);

const data: GithubData = {
  login: "mochi",
  profileUrl: "https://github.com",
  totalStars: 1284,
  // `pushed`: pushes GitHub gave no message for come first, as they often do.
  activity: params.has("empty") ? [] : params.has("pushed") ? [{ ...activity[8], at: minutesAgo(14) }, { ...activity[8], at: minutesAgo(31) }, ...activity] : activity,
  repos: params.has("empty") ? [] : repos,
  // `review`: two pull requests waiting for your review, above the activity.
  toReview: params.has("review") || params.get("news") === "review"
    ? [
      { repo: "louis/coucou", number: 57, title: "Windows: the GitHub panel", url: "https://github.com", author: "edu", draft: false, at: minutesAgo(6), target: pullTarget("louis/coucou", 57) },
      { repo: "mochi/notch", number: 31, title: "Fold the island when the mouse leaves", url: "https://github.com", author: "ada", draft: true, at: minutesAgo(190), target: pullTarget("mochi/notch", 31) },
    ]
    : [],
  contributions: {
    total: counts.reduce((a, b) => a + b, 0),
    start: new Date(firstSunday).toISOString().slice(0, 10),
    counts,
    levels: counts.map(level),
  },
  fetchedAt: Date.now() - (params.has("error") ? 12 * 60_000 : 0),
};

// A project's sheet normally comes from Rust; here every project gets this one.
const runState = ["success", "success", "failure", "success", "success", "neutral", "success", "success"] as const;
const sheet: GithubProject = {
  fullName: "mochi/coucou",
  url: "https://github.com",
  description: "A tiny friend that lives at the top of your screen and keeps an eye on your Claude Code sessions.",
  homepage: "https://coucou.example.com",
  private: false,
  createdAt: "2024-03-12T09:00:00Z",
  stars: 4,
  forks: 1,
  languages: [
    { name: "Rust", color: "#dea584", share: 0.46 },
    { name: "TypeScript", color: "#3178c6", share: 0.38 },
    { name: "CSS", color: "#663399", share: 0.12 },
    { name: "Other", color: null, share: 0.04 },
  ],
  runs: runState.map((state, i) => ({
    id: i, state, workflow: "CI", branch: "main",
    title: i === 0 ? "Keep the last snapshot through an error" : "Earlier work",
    actor: "mochi", url: "https://github.com",
    startedAt: minutesAgo(62 + i * 90), updatedAt: minutesAgo(60 + i * 90),
  })),
  pull: {
    number: 12, title: "GitHub panel for the Windows island", url: "https://github.com",
    state: "merged", author: "mochi", additions: 1320, deletions: 94, changedFiles: 14,
    review: "approved", comments: 3, at: minutesAgo(4),
  },
  deploy: {
    environment: "Production", state: "success", url: "https://coucou.example.com",
    creator: "vercel", sha: "a1b2c3d", at: minutesAgo(58),
  },
  missing: params.has("locked") ? ["Deployments"] : [],
};
// `slow` stands in for a real network, long enough to watch Mochi search.
Bridge.githubProject = async () => {
  const ms = Number(params.get("slow"));
  if (params.has("slow")) await new Promise((r) => setTimeout(r, ms > 100 ? ms : 2500));
  return sheet;
};

// Any clicked day gets this one, after a short wait so the loader shows.
const aDay: GithubDay = {
  items: [
    { kind: "push", repo: "mochi/coucou", title: "4 commits", detail: null, url: "https://github.com", target: pushTarget("mochi/coucou", 4, "main") },
    { kind: "push", repo: "mochi/tour-convention-geneve", title: "1 commit", detail: null, url: "https://github.com", target: pushTarget("mochi/tour-convention-geneve", 1, "main") },
    { kind: "pr_merged", repo: "mochi/coucou", title: "GitHub panel for the Windows island", detail: "#12", url: "https://github.com", target: pullTarget("mochi/coucou", 12) },
    { kind: "review", repo: "louis-cfm/coucou", title: "Fix the hook timeout", detail: "#31", url: "https://github.com", target: pullTarget("louis-cfm/coucou", 31) },
  ],
  privateCount: 2,
};
Bridge.githubDay = async () => {
  await new Promise((r) => setTimeout(r, 900));
  return aDay;
};

State.loadIntegrationTasks();
State.integrations.integration_github = {
  data: data as unknown as Record<string, unknown>,
  error: params.has("error") ? "No connection" : null,
  loaded: true,
  configured: true,
};
// `news=fail`, `news=review` or `news=merge`: what the panel shows when the pill's news comes
// in while it is open.
if (params.has("news")) {
  State.integrations.integration_github.news = params.get("news") === "merge"
    ? { success: true, label: "#12 merged", detail: "GitHub panel for the Windows island", open: { target: pullTarget("mochi/coucou", 12), label: "#12", url: "https://github.com", title: "#12 GitHub panel for the Windows island", facts: [{ kind: "repo", text: "coucou" }, { kind: "by", verb: "merged by", text: "louis" }, { kind: "diff", additions: 1332, deletions: 64 }, { kind: "files", text: "14 files" }] } }
    : params.get("news") === "review"
    ? { success: true, label: "Review requested on coucou", detail: "Windows: the GitHub panel", open: { target: pullTarget("louis/coucou", 57), label: "#57", url: "https://github.com", title: "#57 Windows: the GitHub panel", says: "review requested", facts: [{ kind: "repo", text: "coucou" }, { kind: "by", verb: "opened by", text: "edu" }, { kind: "diff", additions: 1332, deletions: 64 }, { kind: "files", text: "14 files" }] } }
    : { success: false, label: "CI failed on coucou", detail: "main", open: { target: { kind: "run", repo: "mochi/coucou", id: 1 }, label: "CI", url: "https://github.com", title: "CI failed on coucou", facts: [{ kind: "step", text: "test \u203a cargo test" }, { kind: "branch", text: "main" }, { kind: "commit", text: "Keep the last snapshot through an error" }, { kind: "by", verb: "by", text: "mochi" }] } };
}
// With the news, Mochi's state as the island's handler sets it. `view=pill`
// shows it the way it arrives with the island away: GitHub's Mochi at the
// front, the island unfolded on the finished or the error card.
const news = State.integrations.integration_github.news;
const pill = params.get("view") === "pill";
if (news) {
  const task = State.tasks.find((t) => t.id === "integration_github");
  if (task) {
    task.state = news.success ? "finished" : "error";
    task.steps = news.detail ? [news.label, news.detail] : [news.label];
    task.stepIndex = task.steps.length - 1;
  }
}
State.setFocus("integration_github");
// Pinned, so the island doesn't fold away while it's being looked at.
State.isPinned = true;

const island = new Island(document.getElementById("root")!);
if (pill && news) island.alert(news.success ? "finished" : "error");
else island.alert(params.get("view") === "overview" ? "overview" : "github");

// The tab is the panel's own state; get there the way a person would.
if (params.get("tab") === "projects") {
  requestAnimationFrame(() => {
    document.querySelector<HTMLElement>(".gh-trail .gh-step:nth-child(2)")?.click();
    if (params.has("sheet")) {
      requestAnimationFrame(() => document.querySelector<HTMLElement>(".gh-list .gh-row:nth-child(2)")?.click());
    }
  });
}

// `pr`: straight to the project's pull request, once its sheet is up. With
// `talk`, on to what was said on it; `talk=code`, on to its first thread's line.
if (params.has("pr")) {
  const steps = [
    () => document.querySelectorAll<HTMLElement>(".gh-sheet .gh-block")[1],
    ...(params.has("talk") ? [() => [...document.querySelectorAll<HTMLElement>(".gh-sheet button.gh-block")].find((b) => /in the conversation|No comments yet/.test(b.textContent ?? ""))] : []),
    ...(params.get("talk") === "code" ? [() => document.querySelector<HTMLElement>(".gh-thread-head")] : []),
  ];
  const walk = window.setInterval(() => {
    const next = steps[0]?.();
    if (!next) return;
    steps.shift();
    next.click();
    if (steps.length === 0) window.clearInterval(walk);
  }, 200);
}

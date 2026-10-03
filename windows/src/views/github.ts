// The GitHub panel — the view behind the `…` of the GitHub card.
//
// Windows only for now, with no macOS view to port from, so it is built from the
// island's own pieces — the card, the rows, the dots, Mochi's state colours —
// rather than from GitHub's look.

import { h, svg, clear, dot } from "./dom";
import { extBadge, fileKind, highlight, type FileKind } from "./code";
import { ICONS } from "./icons";
import { COLOR, wear } from "./palette";
import { ACTIVITY_STYLE, GITHUB_LEVELS, compact, githubData, repoName, timeAgo, type GithubOpening } from "./integrations";
import {
  Bridge,
  type GithubActivity, type GithubBuild, type GithubCommentsDetail, type GithubCommitsDetail, type GithubContributions,
  type GithubData, type GithubDay, type GithubDeploy, type GithubDetail, type GithubEntry, type GithubFile,
  type GithubIssueDetail, type GithubJob, type GithubLabel, type GithubProject, type GithubPull, type GithubPullDetail,
  type GithubReleaseDetail, type GithubRemark, type GithubRepo, type GithubReviewRequest, type GithubRunDetail, type GithubTarget,
  type GithubThread, type GithubTimed, type IntegrationNews,
} from "../core/bridge";
import type { BotEmoteName, BotStateName } from "../core/layout";
import { hexToRGB, type BotEngine } from "../mochi/engine";
import { createFreeBot, pruneMiniBots } from "../mochi/minibots";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import type { ViewActions, ViewHost } from "./views";

const ID = "integration_github";
/** Where a screen leads when it has no page of its own to give. */
const GITHUB_HOME = "https://github.com";
/** Opening the panel refetches first when what it holds is older than this. */
const STALE_MS = 60_000;
/** A refresh that comes back instantly still turns the arrow once. */
const MIN_SPIN_MS = 500;

type Tab = "activity" | "projects";
/** Kept across openings: the panel comes back on the tab it was left on. */
let tab: Tab = "activity";

/** Same colours as the pill badges: green check, red cross, amber for "going". */
const BUILD_STYLE: Record<GithubBuild["state"], { color: string; label: string }> = {
  success: { color: COLOR.pass, label: "passed" },
  failure: { color: COLOR.red, label: "failed" },
  running: { color: COLOR.amber, label: "running" },
  neutral: { color: COLOR.grey, label: "stopped" },
};

/** "comment" or "comments", by how many there are. */
const plural = (n: number, one: string, many = `${one}s`) => (n === 1 ? one : many);

/** "1 comment", "3 comments". */
const counted = (n: number, one: string, many?: string) => `${n} ${plural(n, one, many)}`;

/** Numbers an element's parts (--i), so each takes its turn when they come in one by one. */
function cascade(el: HTMLElement) {
  Array.from(el.children).forEach((child, i) => (child as HTMLElement).style.setProperty("--i", String(i)));
}

/**
 * Something the panel fetches on a click — a project's sheet, a day of the
 * graph — and how that fetch is going.
 */
interface Pending<T> {
  data: T | null;
  error: string | null;
  loading: boolean;
  /** The loader is up — only for a fetch slow enough to notice. */
  waiting: boolean;
  /** Arrived after a visible wait: the next draw makes an entrance of it. */
  react: boolean;
}

function pending<T>(): Pending<T> {
  return { data: null, error: null, loading: false, waiting: false, react: false };
}

/** A project's sheet. */
interface ProjectScreen extends Pending<GithubProject> {
  type: "project";
  fullName: string;
}

/** The sheet behind a line of activity: a pull request, an issue, commits, a release. */
interface DetailScreen extends Pending<GithubDetail> {
  type: "detail";
  /** A pull request's or a commit's run, job by job: fetched beside the sheet. */
  run?: GithubRunDetail | null;
  target: GithubTarget;
  /** What the line said: the head's title while the sheet loads. */
  label: string;
  /** Where the line used to go — GitHub's page, the way out of a locked sheet. */
  url: string;
}

/** One file's diff, opened from a pull request's or a commit's sheet. Nothing to fetch. */
interface DiffScreen {
  type: "diff";
  file: GithubFile;
  /** The GitHub page the diff belongs to. */
  url: string;
  /** Opened from a thread of comments: the diff opens on its line, the thread under it. */
  thread?: GithubThread;
}

/**
 * One job of a run, step by step. Nothing to fetch: it reads its run's sheet,
 * so a refresh of the run — by hand, or live while it runs — reaches it too.
 */
interface JobScreen {
  type: "job";
  run: DetailScreen;
  jobId: number;
}

type Screen = ProjectScreen | DetailScreen | DiffScreen | JobScreen;

/** The day picked on the graph, by its index in the calendar. */
interface DayPick extends Pending<GithubDay> {
  index: number;
  /** "YYYY-MM-DD". */
  date: string;
  /** The day's lines have been drawn once: later redraws don't replay their entrance. */
  shown: boolean;
}

/**
 * What the panel shows over its lists, deepest last — a project's sheet, the
 * sheet behind a line of activity, a file's diff. Each ‹ goes back one, so
 * GitHub's own site stays the last place to go rather than the first.
 */
let stack: Screen[] = [];
const top = (): Screen | null => stack[stack.length - 1] ?? null;
let day: DayPick | null = null;

/**
 * How the next draw arrives: a deeper screen from the right, back from the
 * left, a tab from its own side, a day's activity rising under the graph.
 * Null — a refresh landing in the background — moves nothing, so what is being
 * read never jumps.
 */
type Motion = "deeper" | "back" | "tab-right" | "tab-left" | "day" | "undo-day";
let motion: Motion | null = null;
/** Bumped on every change to a sheet or a day, so the view knows to redraw. */
let stamp = 0;

/** An answer from the cache comes back at once: no loader for that. */
const LOADER_DELAY_MS = 150;

function touch() {
  stamp += 1;
  State.notify();
}

/**
 * While something is fetched Mochi searches — eyes sweeping, indigo, the "…"
 * badge — the look he has whenever something is being looked up. Only from
 * idle, so a finished or failed state from the pollers is never talked over.
 */
let searchingFor: object | null = null;

function startSearching(for_: object) {
  searchingFor = for_;
  const task = State.tasks.find((t) => t.id === ID);
  if (task?.state === "idle") State.updateTask(ID, "searching");
}

function stopSearching(for_: object) {
  if (searchingFor !== for_) return;
  searchingFor = null;
  const task = State.tasks.find((t) => t.id === ID);
  if (task?.state === "searching") State.updateTask(ID, "idle");
}

/**
 * Fetches into `target`, with the loader and Mochi's search once it has taken
 * long enough to notice. `isCurrent` says whether `target` is still what's on
 * screen: another click may have replaced it, and then it gets no draw.
 */
async function load<T>(target: Pending<T>, isCurrent: () => boolean, fetch: () => Promise<T>) {
  target.loading = true;
  touch();
  const loader = window.setTimeout(() => {
    if (!isCurrent() || !target.loading) return;
    target.waiting = true;
    startSearching(target);
    touch();
  }, LOADER_DELAY_MS);
  try {
    target.data = await fetch();
    target.error = null;
    target.react = target.waiting;
  } catch (err) {
    target.error = String(err).replace(/^Error:\s*/, "");
  } finally {
    window.clearTimeout(loader);
    target.loading = false;
    target.waiting = false;
    stopSearching(target);
    if (isCurrent()) touch();
  }
}

/** One level deeper — with the island's small click. */
function push(screen: Screen) {
  Sound.play("blip");
  stack.push(screen);
  motion = "deeper";
  touch();
}

/** Back up to `depth` screens deep — 0 for the lists. */
function popTo(depth: number) {
  while (stack.length > depth) {
    const left = stack.pop();
    if (left) stopSearching(left);
  }
  motion = "back";
  touch();
}

function clearStack() {
  for (const screen of stack) stopSearching(screen);
  stack = [];
}

function loadProject(screen: ProjectScreen, force: boolean) {
  return load(screen, () => top() === screen, () => Bridge.githubProject(screen.fullName, force));
}

/** The sheet itself is up, or one of its run's jobs is. */
function showing(screen: DetailScreen): boolean {
  const s = top();
  return s === screen || (s?.type === "job" && s.run === screen);
}

async function loadDetail(screen: DetailScreen, force: boolean) {
  await load(screen, () => showing(screen), () => Bridge.githubDetail(screen.target, force));
  await loadRun(screen, force);
}

/** The run a sheet is tied to: a pull request's or a commit's CI. */
function ciOf(screen: DetailScreen): { repo: string; id: number } | null {
  const d = screen.data;
  return (d?.kind === "pull" || d?.kind === "commits") && d.ci ? { repo: d.repo, id: d.ci.id } : null;
}

/**
 * That run's jobs, for the sheet to show under its CI line. Quietly: the
 * sheet is already up, the jobs join it when they come.
 */
async function loadRun(screen: DetailScreen, force: boolean) {
  const ci = ciOf(screen);
  if (!ci) {
    screen.run = null;
    return;
  }
  try {
    const run = await Bridge.githubDetail({ kind: "run", repo: ci.repo, id: ci.id }, force);
    screen.run = run.kind === "run" ? run : null;
  } catch {
    // The CI line still says how it went; the jobs can wait for a refresh.
  }
  if (showing(screen)) touch();
}

/** The run a screen can show the progress of, if any: its own, or its sheet's. */
function runOf(s: Screen | null): GithubRunDetail | null {
  const screen = s ? fetched(s) : null;
  if (screen?.type !== "detail") return null;
  return screen.data?.kind === "run" ? screen.data : (screen.run ?? null);
}

/**
 * A run that was going when last seen and has just ended, while on screen:
 * the view makes a moment of it (Mochi, a sound), once.
 */
let justEnded: "success" | "failure" | "neutral" | null = null;

/** The runs seen ending on screen: the panel has already played those. */
const sawEnd = new Set<number>();

/**
 * True for a run the panel showed ending. Its news arrives a few seconds
 * later from the tick; the island need not play its sound a second time.
 */
export function sawRunEnd(id: number): boolean {
  return sawEnd.has(id);
}

/** How long Mochi wears a run's ending before he is himself again. */
const END_LOOK_MS = 3200;

/** What a screen fetches — a job fetches through its run; a diff has nothing to fetch. */
function fetched(s: Screen): ProjectScreen | DetailScreen | null {
  return s.type === "job" ? s.run : s.type === "diff" ? null : s;
}

/**
 * A run still going asks again every few seconds while it is on screen — its
 * own screen, or the pull request or commit it runs for — so its jobs finish
 * one by one before your eyes. Quietly: no loader, no search from Mochi, the
 * list stays where it was read. Only while the panel is open.
 */
const LIVE_MS = 10_000;
let liveTimer: number | null = null;

function liveRun(): DetailScreen | null {
  const s = top();
  const screen = s ? fetched(s) : null;
  if (screen?.type !== "detail") return null;
  const d = screen.data;
  const going =
    (d?.kind === "run" && d.state === "running") ||
    screen.run?.state === "running" ||
    ((d?.kind === "pull" || d?.kind === "commits") && d.ci?.state === "running");
  return going ? screen : null;
}

/**
 * Somebody is looking at the panel, and Coucou is not paused: the only time a
 * run is asked about again on its own. Pausing Coucou means no network at all.
 */
function watching(): boolean {
  return State.mode === "expanded" && State.view === "github" && !State.paused;
}

function armLive() {
  if (liveTimer != null || !liveRun()) return;
  if (!watching()) return;
  liveTimer = window.setTimeout(async () => {
    liveTimer = null;
    const screen = liveRun();
    if (!screen || screen.loading || !watching()) return;
    try {
      screen.data = await Bridge.githubDetail(screen.target, true);
      screen.error = null;
      await loadRun(screen, true);
    } catch {
      // Offline for a moment: the next round tries again.
    }
    // It was going a moment ago; if it no longer is, it has just ended.
    const run = runOf(screen);
    if (!liveRun() && run && run.state !== "running" && showing(screen)) {
      justEnded = run.state;
      sawEnd.add(run.id);
    }
    // Redraws, which arms the next round while the run still goes.
    if (showing(screen)) touch();
  }, LIVE_MS);
}

function openProject(fullName: string) {
  const screen: ProjectScreen = { ...pending<GithubProject>(), type: "project", fullName };
  push(screen);
  void loadProject(screen, false);
}

/** A line of activity: its sheet in the panel when it has one, GitHub otherwise. */
function openTarget(target: GithubTarget | null, label: string, url: string) {
  if (!target) {
    void Bridge.openUrl(url);
    return;
  }
  if (target.kind === "project") {
    openProject(target.repo);
    return;
  }
  const screen: DetailScreen = { ...pending<GithubDetail>(), type: "detail", target, label, url };
  push(screen);
  void loadDetail(screen, false);
}

function openDiff(file: GithubFile, url: string, thread?: GithubThread) {
  push({ type: "diff", file, url, thread });
}

/** What was said on a pull request, from its sheet. */
function openComments(p: GithubPullDetail) {
  openTarget({ kind: "comments", repo: p.repo, number: p.number }, `#${p.number}`, p.url);
}

/**
 * A thread, in its file's diff. The diff comes from the pull request's sheet,
 * the screen the comments were opened from; only a file that sheet doesn't
 * carry is read on GitHub. A thread whose line is gone — the code has changed
 * since — still opens its file, and heads the diff instead of sitting in it.
 */
function threadFile(c: GithubCommentsDetail, thread: GithubThread): { file: GithubFile; url: string } | null {
  for (const s of stack) {
    const p = s.type === "detail" && s.data?.kind === "pull" ? s.data : null;
    if (!p || p.repo !== c.repo || p.number !== c.number) continue;
    const file = p.files.find((f) => f.path === thread.path);
    if (file?.patch) return { file, url: p.url };
  }
  return null;
}

function openThread(c: GithubCommentsDetail, thread: GithubThread) {
  const found = threadFile(c, thread);
  if (found) openDiff(found.file, found.url, thread);
  else void Bridge.openUrl(thread.remarks[0]?.url ?? c.url);
}

/** A run of Actions: its jobs and how long each took. */
function openRun(repo: string, id: number, workflow: string, url: string) {
  openTarget({ kind: "run", repo, id }, workflow, url);
}

function openJob(run: DetailScreen, job: GithubJob) {
  push({ type: "job", run, jobId: job.id });
}

/** A day's bounds as the island's clock sees it: local midnight to midnight. */
function localDay(date: string): { from: string; to: string; today: boolean } {
  const [y, m, d] = date.split("-").map(Number);
  const from = new Date(y, m - 1, d);
  const next = new Date(y, m - 1, d + 1);
  const now = Date.now();
  return {
    from: from.toISOString(),
    to: new Date(next.getTime() - 1000).toISOString(),
    today: now >= from.getTime() && now < next.getTime(),
  };
}

function loadDay(current: DayPick) {
  const { from, to, today } = localDay(current.date);
  return load(current, () => day === current, () => Bridge.githubDay(from, to, today));
}

/** A second click on the same day lets go of it, as on GitHub. */
function pickDay(index: number, date: string) {
  if (day?.index === index) {
    unpickDay();
    return;
  }
  if (day) stopSearching(day);
  const picked: DayPick = { ...pending<GithubDay>(), index, date, shown: false };
  day = picked;
  motion = "day";
  void loadDay(picked);
}

function unpickDay() {
  if (day) stopSearching(day);
  day = null;
  motion = "undo-day";
  touch();
}

/** What Mochi makes of a sheet: stars for all green, a start for a failure. */
function mood(p: GithubProject): BotEmoteName {
  const failed = p.runs[0]?.state === "failure" || p.deploy?.state === "failure";
  if (failed) return "surprised";
  const green = p.runs[0]?.state === "success" && (!p.deploy || p.deploy.state === "success");
  return green ? "proud" : "happy";
}

/** The graph sweeps in on the next draw: on entering the panel and on its tab. */
let sweepNext = true;

/**
 * On the way into the panel — from the card, or from a piece of news: start
 * from the lists — no sheet, no picked day — and refetch when what they hold
 * is old news; then, when the way in is `open` on something, straight to that.
 *
 * It must end in touch(): the view redraws only when its key changes, and a
 * sheet dropped without a new stamp stayed on screen, with ‹ then leaving the
 * panel since, as far as it knew, no sheet was open.
 */
export function enterGithubPanel(open?: GithubOpening) {
  sweepNext = true;
  if (day) stopSearching(day);
  day = null;
  clearStack();
  // The island's own view transition brings the panel in; the graph sweeps.
  motion = null;
  touch();
  const d = githubData();
  if (!d || Date.now() - d.fetchedAt > STALE_MS) void Bridge.refreshIntegration(ID);
  if (open?.target) openTarget(open.target, open.label ?? "", open.url ?? "");
}

/** One line of GitHub activity — the recent feed, or a picked day. It opens its sheet. */
function eventRow(
  item: {
    kind: keyof typeof ACTIVITY_STYLE; repo: string; title: string; detail: string | null; url: string;
    target: GithubTarget | null;
  },
  login: string,
  ago?: string,
): HTMLElement {
  const style = ACTIVITY_STYLE[item.kind];
  const where = [repoName(item.repo, login), item.detail].filter(Boolean).join(" · ");
  return h(
    "button",
    { class: "gh-row", onclick: () => openTarget(item.target, item.title, item.url) },
    h("i", { class: "gh-row-icon", style: `color:${style.color}` }, svg(style.icon, 12, { stroke: 2 })),
    h("span", { class: "gh-row-title", text: item.title }),
    h("span", { class: "gh-row-where", text: where }),
    ago != null ? h("span", { class: "int-ago", text: ago }) : null,
  );
}

function activityRow(a: GithubActivity, login: string): HTMLElement {
  return eventRow(a, login, timeAgo(a.at));
}

/** A pull request waiting for your review: whose it is, and since when it last moved. */
function reviewRow(r: GithubReviewRequest, login: string): HTMLElement {
  const detail = [`#${r.number}`, r.author, r.draft && "draft"].filter(Boolean).join(" · ");
  return eventRow({ kind: "review", repo: r.repo, title: r.title, detail, url: r.url, target: r.target }, login, timeAgo(r.at));
}

/** A state's mark: a check, a cross, a dash — or, while it goes, a turning ring. */
function stateMark(state: GithubBuild["state"], size: number): Element {
  switch (state) {
    case "running":
      return h("i", { class: "gh-ring" });
    case "success":
      return svg(ICONS.check, size + 1, { stroke: 3 });
    case "failure":
      return svg(ICONS.xmark, size);
    case "neutral":
      return svg(ICONS.dash, size + 1, { stroke: 3 });
  }
}

/** The last Actions run as a small round badge; it opens the run in the panel. */
function buildBadge(build: GithubBuild | null, repo: string): HTMLElement {
  if (!build) return h("span", { class: "gh-build none" });
  const style = BUILD_STYLE[build.state];
  const where = build.branch ? ` on ${build.branch}` : "";
  const badge = h(
    "button",
    {
      class: "gh-build",
      title: `${build.workflow}${where} · ${style.label} ${timeAgo(build.at)} ago`,
      onclick: (e: Event) => {
        e.stopPropagation();
        openRun(repo, build.id, build.workflow, build.url);
      },
    },
    stateMark(build.state, 8),
  );
  wear(badge, style.color);
  return badge;
}

/** Stars and open pull requests keep their column even at zero, so rows line up. */
function meta(icon: SVGSVGElement, count: number, onClick?: () => void): HTMLElement {
  if (count <= 0) return h("span", { class: "gh-meta none" });
  const el = h("span", { class: onClick ? "gh-meta link" : "gh-meta" }, icon, compact(count));
  if (onClick) {
    el.addEventListener("click", (e) => {
      e.stopPropagation();
      onClick();
    });
  }
  return el;
}

/**
 * Whether the pill speaks up for this project — a broken build, a merge, a
 * pull request somebody opened — as a bell on its row. A click mutes it or
 * gives it its voice back; the choice is kept with the settings, where the
 * Rust side reads it before telling any news.
 */
function newsBell(repo: string): HTMLElement {
  const bell = h("button", { class: "gh-bell" });
  const draw = () => {
    const quiet = State.settings.githubMuted.includes(repo);
    clear(bell);
    bell.append(svg(quiet ? ICONS.bellOff : ICONS.bell, 10, { stroke: 2 }));
    bell.classList.toggle("off", quiet);
    bell.title = quiet ? "Muted: no news from this project. Click to hear from it again." : "News from this project. Click to mute it.";
  };
  bell.addEventListener("click", (e) => {
    e.stopPropagation();
    const muted = State.settings.githubMuted;
    State.settings.githubMuted = muted.includes(repo) ? muted.filter((name) => name !== repo) : [...muted, repo];
    void Bridge.saveSettings(State.settings);
    draw();
  });
  draw();
  return bell;
}

/**
 * Your own repositories by name; somebody else's with their owner in front.
 * The row opens the project's sheet, the badge its last run; the PR count
 * stays a shortcut straight to GitHub, and the bell says whether the project
 * speaks up.
 */
function repoRow(repo: GithubRepo, login: string, onOpen: () => void): HTMLElement {
  return h(
    "div",
    { class: "gh-row", onclick: onOpen },
    dot(repo.languageColor ?? COLOR.blank, 6),
    h("span", { class: "gh-row-title", text: repoName(repo.fullName, login) }),
    repo.private ? h("i", { class: "gh-lock", title: "Private" }, svg(ICONS.lock, 9, { stroke: 2.2 })) : null,
    h("span", { class: "gh-row-where", text: repo.language ?? "" }),
    h(
      "span",
      { class: "gh-right" },
      newsBell(repo.fullName),
      buildBadge(repo.build, repo.fullName),
      meta(svg(ICONS.star, 9), repo.stars),
      meta(svg(ICONS.pullRequest, 9, { stroke: 2 }), repo.openPrs, () => void Bridge.openUrl(`${repo.url}/pulls`)),
      h("span", { class: "int-ago", text: repo.pushedAt ? timeAgo(repo.pushedAt) : "" }),
    ),
  );
}

// ── Contribution graph ────────────────────────────────────────────────────────
//
// GitHub's year of squares, in GitHub's own colours, drawn as tiny squircles —
// Mochi's shape. Under the mouse, Mochi takes the colour of the day.

const DAY_MS = 86_400_000;
/** The room between two weeks, in CSS pixels, before it is rounded to the screen's. */
const WEEK_GAP = 1.6;

/** a → b by t, as a hex colour. */
function mixHex(a: string, b: string, t: number): string {
  const ca = parseInt(a.slice(1), 16);
  const cb = parseInt(b.slice(1), 16);
  const channel = (shift: number) => {
    const x = (ca >> shift) & 255;
    const y = (cb >> shift) & 255;
    return Math.round(x + (y - x) * t);
  };
  return `#${((channel(16) << 16) | (channel(8) << 8) | channel(0)).toString(16).padStart(6, "0")}`;
}

/**
 * Per GitHub level, 0 (nothing) to 4 (busiest): the cell's colour, and how
 * green Mochi turns over that day. His shades run from his resting colour to
 * GitHub's brightest green, never through the dark ones: his eyes are
 * ink-dark and would vanish on a dark green body.
 */
const LEVEL_LOOK = [0, 0.4, 0.6, 0.8, 1].map((t, level) => ({
  cell: GITHUB_LEVELS[level],
  mochi: mixHex(COLOR.idle, GITHUB_LEVELS[4], t),
}));

function dayDate(start: string, i: number): Date {
  return new Date(Date.parse(`${start}T00:00:00Z`) + i * DAY_MS);
}

function dayLabel(date: Date, count: number): string {
  const when = date.toLocaleDateString(undefined, {
    weekday: "short", day: "numeric", month: "short", timeZone: "UTC",
  });
  const what = count === 0 ? "No contributions" : counted(count, "contribution");
  return `${what} · ${when}`;
}

/** Days in a row with something, back from today — or from yesterday, when today is still blank. */
function currentStreak(counts: number[]): number {
  let i = counts.length - 1;
  if (i >= 0 && counts[i] === 0) i -= 1;
  let days = 0;
  while (i >= 0 && counts[i] > 0) {
    days += 1;
    i -= 1;
  }
  return days;
}

/** A calendar day's colour for Mochi, by its index. */
function mochiShade(c: GithubContributions, i: number): string {
  return (LEVEL_LOOK[c.levels[i] ?? 0] ?? LEVEL_LOOK[0]).mochi;
}

interface GraphOptions {
  sweep: boolean;
  tint: ViewActions["tintMochi"];
  /** The picked day, if any: the others fade, as on GitHub. */
  picked: number | null;
  /** A day was just picked or let go: the fade plays instead of snapping. */
  settle: "picked" | "unpicked" | null;
  onPick(index: number, date: string): void;
}

/** The graph on show, with what fitting it takes: its grid, and how many weeks it holds. */
let fitted: { grid: HTMLElement; graph: HTMLElement; weeks: number } | null = null;

/**
 * Cells sized as fractions of the width landed on fractions of a screen
 * pixel, so at 125 % some were drawn a pixel wider than others: every day is
 * sized in whole device pixels, all alike. Whole cells leave up to a pixel per
 * week unused — 35 px of empty grid at the right edge — so what is left over
 * goes to the gaps between weeks instead, one device pixel more here and
 * there, spread evenly: a pixel of spacing reads as nothing where a pixel of
 * cell read as a crooked grid. Refitted whenever the width changes (a
 * scrollbar appearing, for one).
 */
const graphFit = new ResizeObserver(() => {
  if (!fitted) return;
  const { grid, graph, weeks } = fitted;
  const available = grid.clientWidth;
  if (!available) return;
  const ratio = window.devicePixelRatio || 1;
  const width = Math.floor(available * ratio);
  const gap = Math.max(1, Math.round(WEEK_GAP * ratio));
  const cell = Math.floor((width - (weeks - 1) * gap) / weeks);
  // Fewer than one pixel per gap: never more than one extra in any of them.
  const spare = width - weeks * cell - (weeks - 1) * gap;
  const share = (i: number) => Math.floor((i * spare) / (weeks - 1));
  const columns: string[] = [];
  for (let i = 0; i < weeks; i++) {
    // A week's column is its cell and the gap after it; the last has none.
    const after = i < weeks - 1 ? gap + share(i + 1) - share(i) : 0;
    columns.push(`${(cell + after) / ratio}px`);
  }
  graph.style.setProperty("--cell", `${cell / ratio}px`);
  graph.style.setProperty("--gap", `${gap / ratio}px`);
  graph.style.setProperty("--columns", columns.join(" "));
});

function contributionGraph(c: GithubContributions, o: GraphOptions): HTMLElement {
  const { sweep, tint, picked, settle } = o;
  // Sunday-first columns, like the profile page; GitHub's first week is partial.
  const offset = dayDate(c.start, 0).getUTCDay();
  const weeks = Math.ceil((offset + c.counts.length) / 7);

  const months = h("div", { class: "gh-months" });
  let previousMonth = -1;
  for (let col = 0; col < weeks; col++) {
    const month = dayDate(c.start, col * 7 - offset).getUTCMonth();
    // The partial month at the very start gets no label: it would sit on top
    // of the next one.
    if (month !== previousMonth && col > 0 && col < weeks - 2) {
      const label = h("span", {
        text: dayDate(c.start, col * 7 - offset).toLocaleDateString(undefined, { month: "short", timeZone: "UTC" }),
      });
      label.style.gridColumn = String(col + 1);
      months.append(label);
    }
    previousMonth = month;
  }

  const grid = h("div", {
    class: [
      "gh-grid",
      sweep ? "sweep" : "",
      picked != null ? "picked" : "",
      settle ? `just-${settle}` : "",
    ].join(" ").trim(),
  });
  for (let i = 0; i < offset; i++) grid.append(h("i", { class: "pad" }));
  c.counts.forEach((_, i) => {
    const level = c.levels[i] ?? 0;
    const look = LEVEL_LOOK[level] ?? LEVEL_LOOK[0];
    const classes = [
      level > 0 ? "lit" : "",
      i === c.counts.length - 1 ? "today" : "",
      i === picked ? "on" : "",
    ].join(" ").trim();
    const cell = h("i", { class: classes, "data-i": String(i) });
    cell.style.setProperty("--c", look.cell);
    cell.style.setProperty("--col", String(Math.floor((offset + i) / 7)));
    grid.append(cell);
  });

  const streak = currentStreak(c.counts);
  const summary =
    `${c.total.toLocaleString()} ${plural(c.total, "contribution")} in the last year` +
    (streak >= 2 ? ` · ${streak} days in a row` : "");
  const caption = h("span", { class: "gh-caption" });
  /** What the caption says when no day is hovered: the picked day, or the year. */
  const restCaption = () => {
    caption.textContent = picked != null ? dayLabel(dayDate(c.start, picked), c.counts[picked] ?? 0) : summary;
    caption.classList.toggle("day", picked != null);
  };
  restCaption();
  // GitHub's key, so the colours read the same as on the profile page.
  const legend = h("span", { class: "gh-legend" }, "Less");
  for (const color of GITHUB_LEVELS) {
    const swatch = h("i");
    swatch.style.setProperty("--c", color);
    legend.append(swatch);
  }
  legend.append("More");

  // Hovering a day says what it holds and turns Mochi that day's green;
  // leaving the grid gives the year back, and Mochi the picked day's colour,
  // or his own. A click picks the day.
  grid.addEventListener("mouseover", (e) => {
    const index = (e.target as HTMLElement).dataset.i;
    if (index == null) return;
    const i = Number(index);
    caption.textContent = dayLabel(dayDate(c.start, i), c.counts[i] ?? 0);
    caption.classList.add("day");
    tint(mochiShade(c, i));
  });
  grid.addEventListener("mouseleave", () => {
    restCaption();
    tint(picked != null ? mochiShade(c, picked) : null);
  });
  grid.addEventListener("click", (e) => {
    const index = (e.target as HTMLElement).dataset.i;
    if (index == null) return;
    const i = Number(index);
    o.onPick(i, dayDate(c.start, i).toISOString().slice(0, 10));
  });

  const graph = h("div", { class: "gh-graph" }, months, grid, h("div", { class: "gh-graph-foot" }, caption, legend));
  graph.style.setProperty("--weeks", String(weeks));

  // Only one graph is ever on show: the one before it is let go.
  if (fitted) graphFit.unobserve(fitted.grid);
  fitted = { grid, graph, weeks };
  graphFit.observe(grid);

  return graph;
}

/**
 * What stands under the graph once a day is picked, in place of the recent
 * activity: that day's commits, pull requests, reviews, issues and new
 * repositories, as GitHub's profile lists them.
 */
function daySection(pick: DayPick, login: string, onClose: () => void): HTMLElement {
  const when = new Date(`${pick.date}T00:00:00Z`).toLocaleDateString(undefined, {
    weekday: "long", day: "numeric", month: "long", timeZone: "UTC",
  });
  const section = h(
    "div",
    { class: "gh-day" },
    h(
      "div",
      { class: "gh-day-head" },
      h("span", { text: `Activity on ${when}` }),
      h("button", { class: "int-back gh-day-close", title: "Back to recent activity", onclick: onClose }, svg(ICONS.xmark, 8)),
    ),
  );

  if (pick.error) {
    section.append(h("div", { class: "int-empty", text: pick.error }));
    return section;
  }
  if (!pick.data) {
    if (pick.waiting) section.append(h("div", { class: "gh-loader-text shimmer", text: "Mochi is looking at that day…" }));
    return section;
  }

  for (const item of pick.data.items) section.append(eventRow(item, login));
  if (pick.data.privateCount > 0) {
    const n = pick.data.privateCount;
    section.append(
      h(
        "div",
        { class: "gh-row muted" },
        h("i", { class: "gh-row-icon" }, svg(ICONS.lock, 10, { stroke: 2.2 })),
        h("span", { class: "gh-row-where", text: `${counted(n, "contribution")} in private repositories` }),
      ),
    );
  }
  if (pick.data.items.length === 0 && pick.data.privateCount === 0) {
    section.append(h("div", { class: "int-empty", text: "Nothing public that day." }));
  }
  // The day's lines come in one by one the first time they are drawn — after a
  // wait, or at once from the cache.
  if (pick.react || !pick.shown) {
    pick.react = false;
    pick.shown = true;
    section.classList.add("enter");
    cascade(section);
  }
  return section;
}

// ── Project sheet ─────────────────────────────────────────────────────────────

/** "2m 14s", "45s", "1h 3m". */
function spoken(ms: number): string {
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${seconds % 60}s`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

/** How long a run took, or has been going. */
function duration(fromIso: string | null, toMs: number): string | null {
  if (!fromIso) return null;
  const ms = toMs - Date.parse(fromIso);
  return Number.isFinite(ms) && ms >= 0 ? spoken(ms) : null;
}

/** "just now" stays as is; everything else reads "2h ago". */
function ago(iso: string): string {
  const t = timeAgo(iso);
  return t === "just now" || t === "" ? t : `${t} ago`;
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

/** A round tinted icon in a state colour — the pill badge, one size up. */
function roundIcon(color: string, icon: Node): HTMLElement {
  const el = h("i", { class: "gh-block-icon" }, icon);
  wear(el, color);
  return el;
}

interface BlockParts {
  icon: HTMLElement;
  title: string;
  right?: Node | string;
  /** The grey second line. */
  sub?: Node[];
  /** Anything that rides at the end of the second line (the CI streak). */
  aside?: Node;
  /** A deeper sheet in the island — preferred to `url`, which leaves for GitHub. */
  open?: () => void;
  url?: string | null;
}

/** One section of the sheet: a tinted icon, a sentence, a grey line under it. */
function block(parts: BlockParts): HTMLElement {
  const text = h(
    "div",
    { class: "gh-block-text" },
    h(
      "div",
      { class: "gh-block-title" },
      h("span", { text: parts.title }),
      parts.right ? h("span", { class: "gh-block-right" }, parts.right) : null,
    ),
  );
  if (parts.sub || parts.aside) {
    text.append(
      h("div", { class: "gh-block-sub" }, h("span", { class: "txt" }, ...(parts.sub ?? [])), parts.aside ?? null),
    );
  }
  const url = parts.url;
  const open = parts.open ?? (url ? () => void Bridge.openUrl(url) : null);
  return open
    ? h("button", { class: "gh-block", onclick: open }, parts.icon, text)
    : h("div", { class: "gh-block" }, parts.icon, text);
}

/**
 * The token's permissions a sheet can be missing, by the names GitHub's
 * settings page gives them — the same words Rust sends (`permission` in
 * github.rs).
 */
const PERMISSION = { actions: "Actions", pulls: "Pull requests", deployments: "Deployments" } as const;

/**
 * A section the token may not read here: say which permission would open it.
 * `what` is the section's own name when the permission's doesn't say it.
 */
function notGranted(permission: string, what = permission): HTMLElement {
  return h(
    "div",
    { class: "gh-block muted" },
    roundIcon(COLOR.grey, svg(ICONS.lock, 9, { stroke: 2.2 })),
    h(
      "div",
      { class: "gh-block-text" },
      h("div", { class: "gh-block-title" }, h("span", { text: `${what} aren't readable with this token` })),
      h("div", { class: "gh-block-sub" }, h("span", { class: "txt", text: `Add “${permission}: Read-only” to it on GitHub.` })),
    ),
  );
}

/** Joins the non-empty pieces of a grey line with " · ". */
function line(...pieces: (Node | string | null | false | undefined)[]): Node[] {
  const out: Node[] = [];
  for (const piece of pieces) {
    if (!piece) continue;
    if (out.length) out.push(document.createTextNode(" · "));
    out.push(typeof piece === "string" ? document.createTextNode(piece) : piece);
  }
  return out;
}

const RUN_VERB: Record<GithubBuild["state"], string> = {
  success: "passed",
  failure: "failed",
  running: "is running",
  neutral: "was stopped",
};

function ciBlock(p: GithubProject): HTMLElement {
  if (p.missing.includes(PERMISSION.actions)) return notGranted(PERMISSION.actions);
  const run = p.runs[0];
  if (!run) {
    return block({
      icon: roundIcon(COLOR.grey, svg(ICONS.dash, 9, { stroke: 3 })),
      title: "No CI here yet",
      sub: line("No GitHub Actions workflow has run in this repository."),
    });
  }
  const style = BUILD_STYLE[run.state];
  const took = run.state === "running"
    ? duration(run.startedAt, Date.now())
    : duration(run.startedAt, Date.parse(run.updatedAt));

  // Oldest on the left, so the streak reads like a timeline.
  const history = [...p.runs].reverse();
  const passed = p.runs.filter((r) => r.state === "success").length;
  const streak = h("span", { class: "gh-streak", title: `${passed} of the last ${p.runs.length} runs passed` });
  for (const r of history) {
    const d = h("i");
    d.style.setProperty("--c", BUILD_STYLE[r.state].color);
    streak.append(d);
  }
  streak.append(h("span", { text: `${passed}/${p.runs.length}` }));

  return block({
    icon: roundIcon(style.color, stateMark(run.state, 9)),
    title: `${run.workflow} ${RUN_VERB[run.state]}${run.branch ? ` on ${run.branch}` : ""}`,
    right: run.state === "running" ? `for ${took ?? "a moment"}` : ago(run.updatedAt),
    sub: line(run.title && `“${run.title}”`, run.actor, run.state !== "running" && took && `in ${took}`),
    aside: streak,
    open: () => openRun(p.fullName, run.id, run.workflow, run.url),
  });
}

const PULL_STYLE: Record<GithubPull["state"], { color: string; icon: string }> = {
  open: { color: COLOR.indigo, icon: ICONS.pullRequest },
  draft: { color: COLOR.dim, icon: ICONS.pullRequest },
  merged: { color: COLOR.green, icon: ICONS.merge },
  closed: { color: COLOR.grey, icon: ICONS.pullRequest },
};

const REVIEW_COLOR: Record<NonNullable<GithubPull["review"]>, string> = {
  approved: COLOR.green,
  "changes requested": COLOR.amber,
  "review required": COLOR.dim,
};

function pullBlock(p: GithubProject): HTMLElement {
  if (p.missing.includes(PERMISSION.pulls)) return notGranted(PERMISSION.pulls);
  const pr = p.pull;
  if (!pr) {
    return block({
      icon: roundIcon(COLOR.grey, svg(ICONS.pullRequest, 10, { stroke: 2 })),
      title: "No pull request yet",
    });
  }
  const style = PULL_STYLE[pr.state];
  const size = h(
    "span",
    {},
    h("span", { class: "gh-add", text: `+${pr.additions}` }),
    " ",
    h("span", { class: "gh-del", text: `−${pr.deletions}` }),
  );
  const review = pr.review ? h("span", { text: pr.review, style: `color:${REVIEW_COLOR[pr.review]}` }) : null;
  const files = counted(pr.changedFiles, "file");
  const comments = counted(pr.comments, "comment");
  return block({
    icon: roundIcon(style.color, svg(style.icon, 10, { stroke: 2 })),
    title: `#${pr.number} ${pr.title}`,
    right: chip(pr.state, style.color),
    sub: line(pr.author && `by ${pr.author}`, size, files, review, pr.comments > 0 && comments, ago(pr.at)),
    open: () => openTarget({ kind: "pull", repo: p.fullName, number: pr.number }, `#${pr.number}`, pr.url),
  });
}

const DEPLOY_STYLE: Record<GithubDeploy["state"], { color: string; say: (env: string) => string }> = {
  success: { color: COLOR.pass, say: (env) => `Live on ${env}` },
  failure: { color: COLOR.red, say: (env) => `Deploy to ${env} failed` },
  running: { color: COLOR.amber, say: (env) => `Deploying to ${env}…` },
  inactive: { color: COLOR.grey, say: (env) => `Was live on ${env}` },
};

/** Nothing at all for a repository that never deploys: most don't. */
function deployBlock(p: GithubProject): HTMLElement | null {
  if (p.missing.includes(PERMISSION.deployments)) return notGranted(PERMISSION.deployments);
  const d = p.deploy;
  if (!d) return null;
  const style = DEPLOY_STYLE[d.state];
  return block({
    icon: roundIcon(style.color, svg(ICONS.rocket, 11, { stroke: 1.8 })),
    title: style.say(d.environment),
    right: ago(d.at),
    sub: line(
      d.creator && `by ${d.creator}`,
      d.sha && h("span", { class: "gh-sha", text: d.sha }),
      d.url && h("span", { class: "gh-host", text: hostOf(d.url) }),
    ),
    url: d.url ?? `${p.url}/deployments`,
  });
}

function languageBar(p: GithubProject): HTMLElement | null {
  if (p.languages.length === 0) return null;
  const bar = h("div", { class: "gh-lang-bar" });
  const legend = h("div", { class: "gh-lang-legend" });
  for (const lang of p.languages) {
    const color = lang.color ?? COLOR.blank;
    const segment = h("i", { title: lang.name });
    segment.style.flex = `${lang.share} 1 0`;
    segment.style.background = color;
    bar.append(segment);
    const percent = lang.share < 0.01 ? "<1" : String(Math.round(lang.share * 100));
    legend.append(h("span", {}, dot(color, 6), `${lang.name} ${percent}%`));
  }
  return h("div", { class: "gh-langs" }, bar, legend);
}

/**
 * What stands in for the sheet while Mochi looks: the island's shimmering
 * text, over three ghosts of the blocks that are coming.
 */
/** Ghosts of the blocks to come, under the loader's line. */
const GHOSTS = 3;

function sheetLoader(name: string): HTMLElement {
  const loader = h("div", { class: "gh-loader" }, h("div", { class: "gh-loader-text shimmer", text: `Mochi is looking into ${name}…` }));
  for (let i = 0; i < GHOSTS; i++) {
    const ghost = h("div", { class: "gh-ghost" }, h("i"), h("div", {}, h("b"), h("span")));
    ghost.style.setProperty("--i", String(i));
    loader.append(ghost);
  }
  return loader;
}

function projectSheet(p: GithubProject): HTMLElement {
  const facts = h("div", { class: "gh-facts" });
  const addFact = (...children: (Node | string)[]) => facts.append(h("span", {}, ...children));
  if (p.private) addFact(svg(ICONS.lock, 9, { stroke: 2.2 }), "Private");
  addFact(svg(ICONS.star, 9), `${compact(p.stars)} ${plural(p.stars, "star")}`);
  if (p.forks > 0) addFact(`${compact(p.forks)} ${plural(p.forks, "fork")}`);
  if (p.createdAt) addFact(`since ${new Date(p.createdAt).getFullYear()}`);
  const homepage = p.homepage;
  if (homepage) {
    facts.append(h("button", { class: "gh-host", text: hostOf(homepage), onclick: () => void Bridge.openUrl(homepage) }));
  }

  const el = h(
    "div",
    { class: "gh-sheet" },
    p.description ? h("div", { class: "gh-desc", text: p.description }) : null,
    facts,
    ciBlock(p),
    pullBlock(p),
    deployBlock(p),
    languageBar(p),
  );
  cascade(el);
  return el;
}

// ── Activity sheets (a click on a line of activity) ───────────────────────────

/** A title that may take two lines, with its state chip. */
function titleRow(title: string, ...chips: (HTMLElement | null)[]): HTMLElement {
  return h("div", { class: "gh-title" }, h("span", { text: title }), ...chips);
}

function chip(text: string, color: string): HTMLElement {
  const el = h("span", { class: "gh-chip", text });
  wear(el, color);
  return el;
}

/** The grey line of facts under a title; the repository goes one level deeper. */
function facts(repo: string, login: string, ...pieces: (Node | string | null | false | undefined)[]): HTMLElement {
  const repoLink = h("button", { class: "gh-host", text: repoName(repo, login), onclick: () => openProject(repo) });
  return h("div", { class: "gh-facts" }, ...line(repoLink, ...pieces));
}

/** GitHub's own label colours. */
function labelChips(labels: GithubLabel[]): HTMLElement | null {
  if (labels.length === 0) return null;
  const row = h("div", { class: "gh-labels" });
  for (const label of labels) {
    const el = h("span", { class: "gh-label", text: label.name });
    el.style.setProperty("--c", label.color);
    row.append(el);
  }
  return row;
}

function description(body: string | null): HTMLElement | null {
  return body ? h("div", { class: "gh-desc long", text: body }) : null;
}

/** A small grey heading inside a sheet ("Files", "Commits"). */
function heading(text: string, aside?: Node): HTMLElement {
  return h("div", { class: "gh-heading" }, h("span", { text }), aside ?? null);
}

function plusMinus(additions: number, deletions: number): HTMLElement {
  return h(
    "span",
    { class: "gh-pm" },
    h("span", { class: "gh-add", text: `+${additions}` }),
    " ",
    h("span", { class: "gh-del", text: `−${deletions}` }),
  );
}

/** "windows/src/views/" and "github.ts". */
function splitPath(path: string): { dir: string; base: string } {
  const i = path.lastIndexOf("/");
  return i < 0 ? { dir: "", base: path } : { dir: path.slice(0, i + 1), base: path.slice(i + 1) };
}

/** Mochi's state colours again: new green, gone red, moved indigo, changed amber. */
const FILE_STATUS: Record<string, { color: string }> = {
  added: { color: COLOR.green },
  removed: { color: COLOR.red },
  renamed: { color: COLOR.indigo },
  copied: { color: COLOR.indigo },
};
const MODIFIED = { color: COLOR.amber };

/**
 * What happened to a file, in GitHub's own word. "modified" is what nearly
 * every file of a change is, so it stays grey; a file added, removed or moved
 * is the news, and wears its colour.
 */
function statusWord(file: GithubFile): HTMLElement {
  const word = h("span", { class: "gh-file-status", text: file.status ?? "modified" });
  const known = FILE_STATUS[file.status ?? ""];
  if (known) word.style.color = known.color;
  return word;
}

/**
 * The facts of a piece of news, each drawn as what it is, the way the panel
 * draws them in its sheets: the project and who did it in clear, the size in
 * green and red, a branch in the code face, the step that broke in red.
 */
export function newsFacts(news: IntegrationNews): Node[] {
  const facts = news.open?.facts;
  if (!facts) return news.detail ? [h("span", { class: "nf", text: news.detail })] : [];
  return facts.map((f) => {
    switch (f.kind) {
      case "repo":
        return h("span", { class: "nf strong" }, svg(ICONS.stack, 10), f.text ?? "");
      case "by":
        return h("span", { class: "nf" }, `${f.verb ?? "by"} `, h("b", { text: f.text ?? "" }));
      case "diff":
        return h("span", { class: "nf" }, plusMinus(f.additions ?? 0, f.deletions ?? 0));
      case "files":
        return h("span", { class: "nf" }, svg(ICONS.doc, 10), f.text ?? "");
      case "branch":
        return h("span", { class: "nf" }, h("span", { class: "gh-sha nf-branch", text: f.text ?? "" }));
      case "step":
        return h("span", { class: "nf bad" }, svg(ICONS.xmark, 9), f.text ?? "");
      case "commit":
        return h("span", { class: "nf quote" }, svg(ICONS.commit, 11, { stroke: 2 }), f.text ?? "");
    }
  });
}

/** One file touched, under its extension's badge; it opens the file's diff. */
function fileRow(file: GithubFile, url: string): HTMLElement {
  const { dir, base } = splitPath(file.path);
  return h(
    "button",
    { class: "gh-row gh-file", onclick: () => openDiff(file, url) },
    h("i", { class: "gh-row-icon" }, extBadge(file.path)),
    h("span", { class: "gh-row-title", text: base }),
    h("span", { class: "gh-row-where", text: dir }),
    statusWord(file),
    plusMinus(file.additions, file.deletions),
  );
}

function fileList(files: GithubFile[], url: string, title: string): Node[] {
  if (files.length === 0) return [];
  return [heading(title), ...files.map((f) => fileRow(f, url))];
}

/** A run of Actions on a commit or a pull request, as a block that opens the run. */
function runBlock(build: GithubBuild | null, missing: string[], repo: string): HTMLElement | null {
  if (missing.includes(PERMISSION.actions)) return notGranted(PERMISSION.actions);
  if (!build) return null;
  const style = BUILD_STYLE[build.state];
  return block({
    icon: roundIcon(style.color, stateMark(build.state, 9)),
    title: `${build.workflow} ${RUN_VERB[build.state]}${build.branch ? ` on ${build.branch}` : ""}`,
    right: ago(build.at),
    open: () => openRun(repo, build.id, build.workflow, build.url),
  });
}

// ── What was said on a pull request ───────────────────────────────────────────
//
// The description, the comments, the reviews and the threads on the code, in
// the order they were said. To read: Coucou's token cannot write, so there is
// nothing to answer with; the way out to GitHub is in the panel's head.

/** A review asked for your eyes, like a question: Mochi's `question` cyan. */
const TALK_COLOR = COLOR.cyan;

const VERDICT: Record<string, { say: string; color: string; icon: () => SVGSVGElement }> = {
  approved: { say: "approved", color: COLOR.green, icon: () => svg(ICONS.check, 10, { stroke: 2.4 }) },
  "changes requested": { say: "requested changes", color: COLOR.amber, icon: () => svg(ICONS.bang, 10) },
  commented: { say: "reviewed", color: TALK_COLOR, icon: () => svg(ICONS.comment, 10, { stroke: 2 }) },
  dismissed: { say: "review dismissed", color: COLOR.grey, icon: () => svg(ICONS.dash, 9, { stroke: 3 }) },
};

/** Who, what they did if it has a word, and when. */
function remarkHead(r: GithubRemark, did?: { say: string; color?: string }): HTMLElement {
  const word = did ? h("span", { class: "gh-say-did", text: did.say }) : null;
  if (word && did?.color) word.style.color = did.color;
  return h(
    "div",
    { class: "gh-say-head" },
    h("b", { text: r.author ?? "ghost" }),
    word,
    h("span", { class: "int-ago", text: r.at ? timeAgo(r.at) : "" }),
  );
}

/** What they wrote, as they wrote it; a text cut short ends on its way to GitHub. */
function remarkBody(r: GithubRemark): (HTMLElement | null)[] {
  return [
    r.body ? h("div", { class: "gh-say-body", text: r.body }) : null,
    r.cut ? h("button", { class: "gh-host", text: "The rest is on GitHub", onclick: () => void Bridge.openUrl(r.url) }) : null,
  ];
}

/** A description, a comment or a review: a round mark, then who said what. */
function sayRow(entry: Exclude<GithubEntry, { kind: "thread" }>): HTMLElement {
  const verdict = entry.kind === "review" ? VERDICT[entry.state] : null;
  const icon = verdict
    ? roundIcon(verdict.color, verdict.icon())
    : entry.kind === "description"
      ? roundIcon(COLOR.dim, svg(ICONS.pullRequest, 10, { stroke: 2.2 }))
      : roundIcon(TALK_COLOR, svg(ICONS.comment, 10, { stroke: 2 }));
  const did = verdict ?? (entry.kind === "description" ? { say: "opened the pull request" } : undefined);
  return h(
    "div",
    { class: "gh-block gh-say" },
    icon,
    h("div", { class: "gh-block-text" }, remarkHead(entry, did), ...remarkBody(entry)),
  );
}

/** A line of a diff: its number, its sign, its code in an editor's colours. */
function diffLine(number: number | null, sign: string, text: string, kind: FileKind): HTMLElement {
  const change = sign === "+" ? "add" : sign === "-" ? "del" : "ctx";
  return h(
    "div",
    { class: `gh-diff-line ${change}` },
    h("span", { class: "n", text: number == null ? "" : String(number) }),
    h("span", { class: "s", text: change === "ctx" ? "" : sign }),
    // A line that is gone is only struck through — its words, not the
    // indentation before them; the others are coloured.
    change === "del"
      ? h("span", { class: "t" }, text.slice(0, text.length - text.trimStart().length), h("span", { class: "gone", text: text.trimStart() }))
      : h("span", { class: "t" }, ...highlight(text, kind)),
  );
}

/**
 * The lines a thread is about, without the indentation they all share: the
 * panel is narrow, and what matters here is the line, not how deep it sits.
 */
function dedent(code: GithubThread["code"]): GithubThread["code"] {
  const depths = code.filter((l) => l.text.trim()).map((l) => l.text.length - l.text.trimStart().length);
  const shared = depths.length ? Math.min(...depths) : 0;
  return shared > 0 ? code.map((l) => ({ ...l, text: l.text.slice(shared) })) : code;
}

/** The replies of a thread, one under the other. */
function threadTalk(thread: GithubThread): HTMLElement {
  const more = `${counted(thread.more, "more reply", "more replies")} on GitHub`;
  const last = thread.remarks[thread.remarks.length - 1];
  return h(
    "div",
    { class: "gh-thread-talk" },
    ...thread.remarks.map((r) => h("div", { class: "gh-thread-say" }, remarkHead(r), ...remarkBody(r))),
    thread.more > 0 && last
      ? h("button", { class: "gh-host", text: more, onclick: () => void Bridge.openUrl(last.url) })
      : null,
  );
}

/**
 * A thread on the code: the file and the line it sits on, the lines it is
 * about, then what was said. Its head opens the file's diff on that line. A
 * resolved thread is settled: it folds to its head and who took part.
 */
function threadBlock(c: GithubCommentsDetail, thread: GithubThread): HTMLElement {
  const { dir, base } = splitPath(thread.path);
  const state = thread.resolved ? "resolved" : thread.outdated ? "outdated" : null;
  const found = threadFile(c, thread);
  const onLine = found?.file.patch != null && threadRow(found.file.patch, thread) != null;
  const head = h(
    "button",
    {
      class: "gh-thread-head",
      title: !found ? "Open this thread on GitHub" : onLine ? `Open ${base} on this line` : `Open ${base}`,
      onclick: () => openThread(c, thread),
    },
    h("i", { class: "gh-row-icon" }, extBadge(thread.path)),
    h("span", { class: "gh-row-title", text: thread.line != null ? `${base}:${thread.line}` : base }),
    h("span", { class: "gh-row-where", text: dir }),
    state ? h("span", { class: "gh-file-status", text: state }) : null,
    // Its file isn't among the ones the sheet carries: this one leaves for GitHub.
    found ? null : h("span", { class: "gh-thread-out" }, svg(ICONS.arrowUpRight, 9)),
  );
  if (thread.resolved) {
    const people = [...new Set(thread.remarks.map((r) => r.author ?? "ghost"))];
    const count = thread.remarks.length + thread.more;
    return h(
      "div",
      { class: "gh-thread resolved" },
      head,
      h("div", { class: "gh-thread-sum", text: `${people.join(", ")} · ${counted(count, "comment")}` }),
    );
  }
  const kind = fileKind(thread.path);
  return h(
    "div",
    { class: "gh-thread" },
    head,
    thread.code.length
      ? h("div", { class: "gh-diff" }, ...dedent(thread.code).map((l) => diffLine(l.number, l.sign, l.text, kind)))
      : null,
    threadTalk(thread),
  );
}

function commentsView(c: GithubCommentsDetail, login: string): HTMLElement {
  const said = c.entries.filter((e) => e.kind !== "description" && e.kind !== "thread").length;
  const threads = c.entries.filter((e) => e.kind === "thread");
  const open = threads.filter((t) => t.kind === "thread" && !t.resolved).length;
  return h(
    "div",
    { class: "gh-sheet" },
    titleRow(`#${c.number} ${c.title}`),
    facts(
      c.repo, login,
      said > 0 && counted(said, "comment"),
      threads.length > 0 && `${threads.length} on the code`,
      threads.length > 0 && (open === 0 ? "all resolved" : `${open} to resolve`),
    ),
    c.earlier
      ? h("button", { class: "gh-host", text: "Earlier ones are on GitHub", onclick: () => void Bridge.openUrl(c.url) })
      : null,
    ...c.entries.map((entry) => (entry.kind === "thread" ? threadBlock(c, entry) : sayRow(entry))),
    said + threads.length === 0
      ? h("div", { class: "int-empty", text: c.entries.length ? "Nobody has commented yet." : "No description, and nobody has commented yet." })
      : null,
  );
}

/** The way into what was said, from the pull request's sheet. */
function commentsBlock(p: GithubPullDetail): HTMLElement {
  const total = p.comments + p.threads;
  return block({
    icon: roundIcon(total > 0 ? TALK_COLOR : COLOR.dim, svg(ICONS.comment, 10, { stroke: 2 })),
    title: total === 0 ? "No comments yet" : counted(total, "comment"),
    sub: total === 0
      ? line("Its description is in here")
      : line(p.comments > 0 && `${p.comments} in the conversation`, p.threads > 0 && `${p.threads} on the code`),
    open: () => openComments(p),
  });
}

const REVIEW_TITLE: Record<string, string> = {
  approved: "Approved",
  "changes requested": "Changes requested",
  "review required": "Waiting for a review",
};

function reviewBlock(p: GithubPullDetail): HTMLElement {
  const color = p.review ? REVIEW_COLOR[p.review] : COLOR.grey;
  const who = p.reviewers.map((r) => `${r.login} ${r.state}`);
  return block({
    icon: roundIcon(color, svg(p.review === "approved" ? ICONS.check : ICONS.pullRequest, 10, { stroke: 2.4 })),
    title: p.review ? REVIEW_TITLE[p.review] : p.reviewers.length ? "Reviewed" : "No review yet",
    sub: who.length ? line(...who) : undefined,
  });
}

/**
 * The jobs of a sheet's run, under its CI line: each with its bar, as on the
 * run's own screen, which a click on any of them opens.
 */
function ciJobs(screen: DetailScreen): HTMLElement[] {
  const run = screen.run;
  const ci = ciOf(screen);
  if (!run || !ci || run.id !== ci.id || run.jobs.length === 0) return [];
  const now = Date.now();
  const whole = envelope(run.jobs, now);
  return run.jobs.map((job) => {
    const broke = job.steps.find((s) => s.state === "failure");
    const going = job.steps.find((s) => s.state === "running" && !WAITING.has(s.outcome));
    const where = broke ? `at “${broke.name}”` : going ? going.name : job.runner;
    return timedRow(
      job, job.name, where, whole, now,
      () => openRun(run.repo, run.id, run.workflow, run.url),
      crewMember(run.id, job),
    );
  });
}

function pullView(p: GithubPullDetail, login: string, screen: DetailScreen): HTMLElement {
  const style = PULL_STYLE[p.state];
  const branches = p.head && p.base ? h("span", { class: "gh-sha", text: `${p.head} → ${p.base}` }) : null;
  const when =
    p.state === "merged" && p.mergedAt
      ? `merged ${ago(p.mergedAt)}${p.mergedBy ? ` by ${p.mergedBy}` : ""}`
      : p.state === "closed" && p.closedAt
        ? `closed ${ago(p.closedAt)}`
        : p.createdAt && `opened ${ago(p.createdAt)}`;
  const commits = counted(p.commits, "commit");
  return h(
    "div",
    { class: "gh-sheet" },
    titleRow(`#${p.number} ${p.title}`, chip(p.state, style.color)),
    facts(p.repo, login, p.author && `by ${p.author}`, branches, when),
    labelChips(p.labels),
    runBlock(p.ci, p.missing, p.repo),
    ...ciJobs(screen),
    reviewBlock(p),
    commentsBlock(p),
    block({
      icon: roundIcon(COLOR.dim, svg(ICONS.doc, 10)),
      title: `${counted(p.changedFiles, "file")} changed`,
      right: plusMinus(p.additions, p.deletions),
      sub: line(commits),
    }),
    ...fileList(p.files, p.url, "Files"),
  );
}

const ISSUE_COLOR: Record<GithubIssueDetail["state"], string> = {
  open: COLOR.amber,
  completed: COLOR.green,
  "not planned": COLOR.grey,
  closed: COLOR.grey,
};

function issueView(i: GithubIssueDetail, login: string): HTMLElement {
  const when = i.closedAt ? `closed ${ago(i.closedAt)}` : i.createdAt && `opened ${ago(i.createdAt)}`;
  return h(
    "div",
    { class: "gh-sheet" },
    titleRow(`#${i.number} ${i.title}`, chip(i.state, ISSUE_COLOR[i.state])),
    facts(
      i.repo, login,
      i.author && `by ${i.author}`,
      when,
      i.comments > 0 && counted(i.comments, "comment"),
      i.assignees.length > 0 && `assigned to ${i.assignees.join(", ")}`,
    ),
    labelChips(i.labels),
    description(i.body) ?? h("div", { class: "int-empty", text: "No description." }),
  );
}

function commitsView(c: GithubCommitsDetail, login: string, screen: DetailScreen): HTMLElement {
  const count = c.total ?? c.commits.length;
  const single = c.commits.length === 1 && count <= 1;
  const newest = c.commits[0];
  const title = single && newest
    ? newest.message
    : `${counted(count, "commit")}${c.branch ? ` on ${c.branch}` : ""}`;
  const rows = c.commits.map((commit) => {
    // From a list, a commit opens its own sheet; alone, it is already open.
    const open = single
      ? () => void Bridge.openUrl(commit.url)
      : () => openTarget(
          { kind: "commits", repo: c.repo, head: commit.id, count: 1, branch: c.branch, author: null, from: null, to: null },
          commit.message,
          commit.url,
        );
    return h(
      "button",
      { class: "gh-row", onclick: open },
      h("i", { class: "gh-row-icon", style: `color:${COLOR.blue}` }, svg(ICONS.commit, 12, { stroke: 2 })),
      h("span", { class: "gh-row-title", text: commit.message }),
      h("span", { class: "gh-row-where" }, h("span", { class: "gh-sha", text: commit.sha }), commit.author ? ` · ${commit.author}` : ""),
      h("span", { class: "int-ago", text: commit.at ? timeAgo(commit.at) : "" }),
    );
  });
  const more = count > c.commits.length ? h("div", { class: "int-empty", text: `and ${count - c.commits.length} more on GitHub` }) : null;
  const changed = c.additions != null && c.deletions != null ? plusMinus(c.additions, c.deletions) : undefined;
  return h(
    "div",
    { class: "gh-sheet" },
    titleRow(title, single && newest ? chip(newest.sha, COLOR.blue) : null),
    facts(c.repo, login, newest?.author && `by ${newest.author}`, newest?.at && ago(newest.at)),
    runBlock(c.ci, c.missing, c.repo),
    ...ciJobs(screen),
    ...(single ? [] : [heading("Commits"), ...rows, more]).filter((n): n is HTMLElement => n != null),
    ...(c.files.length ? [heading(single ? "Files" : "Latest commit", changed), ...c.files.map((f) => fileRow(f, newest?.url ?? c.url))] : []),
  );
}

/** 12345678 → "11.8 MB". */
function size(bytes: number): string {
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value < 10 && unit > 0 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

function releaseView(r: GithubReleaseDetail, login: string): HTMLElement {
  const assets = r.assets.map((a) =>
    h(
      "div",
      { class: "gh-row" },
      h("i", { class: "gh-row-icon", style: `color:${COLOR.cyan}` }, svg(ICONS.tag, 11, { stroke: 2 })),
      h("span", { class: "gh-row-title", text: a.name }),
      h("span", { class: "gh-row-where", text: size(a.size) }),
      h("span", { class: "int-ago", text: `${compact(a.downloads)} ↓` }),
    ),
  );
  return h(
    "div",
    { class: "gh-sheet" },
    titleRow(r.name, chip(r.tag, COLOR.cyan), r.prerelease ? chip("pre-release", COLOR.amber) : null),
    facts(
      r.repo, login,
      r.author && `by ${r.author}`,
      r.publishedAt && `published ${ago(r.publishedAt)}`,
      r.downloads > 0 && `${compact(r.downloads)} ${plural(r.downloads, "download")}`,
    ),
    ...(assets.length ? [heading("Files"), ...assets] : []),
    description(r.body),
  );
}

// ── A run of Actions ──────────────────────────────────────────────────────────
//
// Every job of a run on one timeline, and every step of a job on another, the
// way GitHub draws a run: where each part started, how long it went, which ones
// ran side by side, and where the time went.

interface Span {
  from: number;
  to: number;
}

/** When a part ran, in ms; a running one ends now, a waiting one hasn't begun. */
function spanOf(t: GithubTimed, now: number): Span | null {
  if (!t.startedAt || t.outcome === "skipped") return null;
  const from = Date.parse(t.startedAt);
  const to = t.endedAt ? Date.parse(t.endedAt) : now;
  return Number.isFinite(from) && Number.isFinite(to) ? { from, to: Math.max(from, to) } : null;
}

/** From the first start to the last end: the width of the timeline. */
function envelope(parts: GithubTimed[], now: number): Span | null {
  const spans = parts.map((p) => spanOf(p, now)).filter((s): s is Span => s != null);
  if (spans.length === 0) return null;
  return { from: Math.min(...spans.map((s) => s.from)), to: Math.max(...spans.map((s) => s.to)) };
}

/** "2m 14s" — or, for what never ran, what it is: "queued", "skipped". */
function took(t: GithubTimed, now: number): string {
  const span = spanOf(t, now);
  return span ? spoken(span.to - span.from) : t.outcome;
}

const WAITING = new Set(["queued", "waiting", "waiting for approval"]);

/** "Took 3m 2s", "Running for 40s", "Queued". */
function tookTitle(t: GithubTimed, now: number): string {
  if (WAITING.has(t.outcome)) return t.outcome.charAt(0).toUpperCase() + t.outcome.slice(1);
  return t.state === "running" ? `Running for ${took(t, now)}` : `Took ${took(t, now)}`;
}

/** A part's mark; a hollow circle for one still waiting for its turn. */
function timedMark(t: GithubTimed): Element {
  return WAITING.has(t.outcome) ? h("i", { class: "gh-wait" }) : stateMark(t.state, 8);
}

/**
 * Jobs queued together are picked up by their runners a few seconds apart.
 * That is not one job waiting for another, and drawn on the timeline it is
 * only a bar that looks as if it failed to fill from the left: a job that
 * started this soon after the first one is drawn as starting with it.
 */
const PICKUP_MS = 10_000;

/**
 * Where a part sits on its timeline: a bar that starts and ends when it did.
 * A job's (`job`) leaves a gap on its left only for a wait worth the name —
 * one that needed another job to end — and then says so on hover.
 */
function bar(t: GithubTimed, whole: Span | null, now: number, job = false): HTMLElement {
  const track = h("span", { class: "gh-bar" });
  const span = spanOf(t, now);
  if (!whole || !span) return track;
  const length = Math.max(whole.to - whole.from, 1);
  const late = span.from - whole.from;
  const from = job && late < PICKUP_MS ? whole.from : span.from;
  if (job && from > whole.from) track.title = `Started ${spoken(late)} after the first job`;
  const segment = h("i", { class: t.state === "running" ? "live" : "" });
  segment.style.left = `${((from - whole.from) / length) * 100}%`;
  segment.style.width = `${((span.to - from) / length) * 100}%`;
  segment.style.setProperty("--c", BUILD_STYLE[t.state].color);
  track.append(segment);
  return track;
}

// ── A run's crew ──────────────────────────────────────────────────────────────
//
// Each job of a run is a mini Mochi — the island's own way of showing something
// at work beside the big one. He sleeps while his job waits for a runner, works
// while it runs, and the engine plays the rest as for any Mochi: a roll and
// sparks the moment it passes, a shake the moment it breaks.

/** A job's Mochi: his state, and the colour of his body. */
function crewLook(t: GithubTimed): { state: BotStateName; color: string } {
  if (WAITING.has(t.outcome)) return { state: "sleeping", color: COLOR.asleep };
  switch (t.state) {
    case "running":
      return { state: "working", color: BUILD_STYLE.running.color };
    case "success":
      return { state: "finished", color: BUILD_STYLE.success.color };
    case "failure":
      return { state: "error", color: BUILD_STYLE.failure.color };
    case "neutral":
      return { state: "idle", color: BUILD_STYLE.neutral.color };
  }
}

/** The body of a job's Mochi, in px: a row's line of text, and a little more. */
const CREW_SIZE = 17;
/** At that size a mini's eyes are too big to tell his expressions apart. */
const CREW_EYES = 0.72;

/**
 * The Mochis on show, by run and job. Kept from one draw to the next: a job
 * that passes between two refreshes is then a change its Mochi plays, not a
 * new Mochi that was always green.
 */
const crew = new Map<string, { el: HTMLElement; engine: BotEngine }>();

function crewMember(runId: number, job: GithubJob): HTMLElement {
  const key = `${runId}:${job.id}`;
  const look = crewLook(job);
  let member = crew.get(key);
  if (!member) {
    member = createFreeBot(look.color, look.state, CREW_SIZE, CREW_EYES);
    crew.set(key, member);
  } else {
    member.engine.bodyColor = hexToRGB(look.color);
    member.engine.setState(look.state);
  }
  return member.el;
}

/** Lets go of the Mochis whose row has left the screen. */
function dismissCrew() {
  for (const [key, member] of crew) {
    if (!member.el.isConnected) crew.delete(key);
  }
  pruneMiniBots();
}

/**
 * A job or a step: its mark, its name, how long it took, and its bar under
 * them. A job comes with its Mochi (`mark`) in place of the plain mark.
 */
function timedRow(
  t: GithubTimed, name: string, where: string | null, whole: Span | null, now: number,
  open?: () => void, mark?: HTMLElement,
): HTMLElement {
  const parts = [
    mark
      ? h("i", { class: "gh-row-icon" }, mark)
      : h("i", { class: "gh-row-icon", style: `color:${BUILD_STYLE[t.state].color}` }, timedMark(t)),
    h("span", { class: "gh-row-title", text: name }),
    where ? h("span", { class: "gh-row-where", text: where }) : null,
    h("span", { class: "int-ago gh-took", text: took(t, now) }),
    bar(t, whole, now, mark != null),
  ];
  const cls = mark ? "gh-row gh-timed gh-crew" : "gh-row gh-timed";
  return open ? h("button", { class: cls, onclick: open }, ...parts) : h("div", { class: cls }, ...parts);
}

/** "3 passed · 1 failed". */
function tally(parts: GithubTimed[]): string[] {
  const counts = new Map<string, number>();
  for (const p of parts) counts.set(p.outcome, (counts.get(p.outcome) ?? 0) + 1);
  return [...counts].map(([word, n]) => `${n} ${word}`);
}

const EVENT_WORDS: Record<string, string> = {
  push: "on push",
  pull_request: "on a pull request",
  pull_request_target: "on a pull request",
  schedule: "on schedule",
  workflow_dispatch: "started by hand",
  release: "on a release",
  merge_group: "in the merge queue",
};

function runView(r: GithubRunDetail, login: string, screen: DetailScreen): HTMLElement {
  const now = Date.now();
  const whole = envelope(r.jobs, now);
  const style = BUILD_STYLE[r.state];
  const count = r.jobs.length + r.moreJobs;
  return h(
    "div",
    { class: "gh-sheet" },
    titleRow(r.title ?? r.workflow, chip(r.outcome, style.color)),
    facts(
      r.repo, login,
      r.branch && h("span", { class: "gh-sha", text: r.branch }),
      r.event && (EVENT_WORDS[r.event] ?? r.event),
      r.actor && `by ${r.actor}`,
      r.attempt > 1 && `attempt ${r.attempt}`,
      r.startedAt && `started ${ago(r.startedAt)}`,
    ),
    block({
      icon: roundIcon(style.color, svg(ICONS.timer, 11)),
      title: tookTitle(r, now),
      right: counted(count, "job"),
      sub: r.jobs.length ? line(...tally(r.jobs)) : undefined,
    }),
    heading("Jobs"),
    ...r.jobs.map((job) => {
      // A failed job says where it broke; the others, what they ran on.
      const broke = job.steps.find((s) => s.state === "failure");
      return timedRow(
        job, job.name, broke ? `at “${broke.name}”` : job.runner, whole, now,
        () => openJob(screen, job),
        crewMember(r.id, job),
      );
    }),
    r.moreJobs > 0 ? h("div", { class: "int-empty", text: `and ${r.moreJobs} more on GitHub` }) : null,
    r.jobs.length === 0
      ? h("div", { class: "int-empty", text: r.state === "running" ? "Waiting for the first job…" : "No jobs to show." })
      : null,
  );
}

function jobView(job: GithubJob, run: GithubRunDetail): HTMLElement {
  const now = Date.now();
  const whole = envelope(job.steps, now);
  const style = BUILD_STYLE[job.state];
  const broke = job.steps.find((s) => s.state === "failure");
  return h(
    "div",
    { class: "gh-sheet" },
    titleRow(job.name, chip(job.outcome, style.color)),
    h("div", { class: "gh-facts" }, ...line(run.workflow, job.runner, job.startedAt && `started ${ago(job.startedAt)}`)),
    block({
      icon: roundIcon(style.color, svg(ICONS.timer, 11)),
      title: tookTitle(job, now),
      right: counted(job.steps.length, "step"),
      sub: broke ? line(`broke at “${broke.name}”`) : job.steps.length ? line(...tally(job.steps)) : undefined,
    }),
    heading("Steps"),
    ...job.steps.map((step) => timedRow(step, step.name, null, whole, now)),
    job.steps.length === 0 ? h("div", { class: "int-empty", text: "No steps yet." }) : null,
    h("button", { class: "gh-host", text: "Its logs are on GitHub", onclick: () => void Bridge.openUrl(job.url) }),
  );
}

/** What a whole sheet is called when its permission's name doesn't say it. */
const LOCKED_WHAT: Record<string, string> = {
  Contents: "Commits and releases",
  Actions: "Actions runs",
};

function detailView(d: GithubDetail, login: string, screen: DetailScreen): HTMLElement {
  switch (d.kind) {
    case "pull":
      return pullView(d, login, screen);
    case "issue":
      return issueView(d, login);
    case "commits":
      return commitsView(d, login, screen);
    case "release":
      return releaseView(d, login);
    case "run":
      return runView(d, login, screen);
    case "comments":
      return commentsView(d, login);
    case "locked":
      return h(
        "div",
        { class: "gh-sheet" },
        notGranted(d.permission, LOCKED_WHAT[d.permission]),
        h("button", { class: "gh-host", text: "Open it on GitHub instead", onclick: () => void Bridge.openUrl(screen.url) }),
      );
  }
}

/** What Mochi makes of a sheet that took a moment: pleased, proud, or startled by a failure. */
function detailMood(d: GithubDetail): BotEmoteName | null {
  switch (d.kind) {
    case "pull":
      return d.ci?.state === "failure" ? "surprised" : d.state === "merged" ? "proud" : "happy";
    case "commits":
      return d.ci?.state === "failure" ? "surprised" : "happy";
    case "issue":
      return d.state === "completed" ? "proud" : "happy";
    case "release":
      return "proud";
    case "run":
      return d.state === "failure" ? "surprised" : d.state === "success" ? "proud" : null;
    case "comments":
    case "locked":
      return null;
  }
}

/** The job a job screen is about, in its run's latest sheet. */
function jobOf(s: JobScreen): { job: GithubJob; run: GithubRunDetail } | null {
  const run = s.run.data?.kind === "run" ? s.run.data : null;
  const job = run?.jobs.find((j) => j.id === s.jobId);
  return run && job ? { job, run } : null;
}

/**
 * What kind of screen this is, said three ways at once so it can't be
 * mistaken for another: an icon, a word, and a colour — for the tab's badge,
 * the rule under the tab, and the screen's mark in the column's trail. The
 * colours are the island's own (amber for something waiting, red for an
 * error).
 */
interface ScreenLook {
  label: string;
  color: string;
  icon: () => SVGSVGElement;
  /** A mark of its own in place of the tinted round icon: a file's extension badge. */
  mark?: () => HTMLElement;
}

function screenLook(screen: Screen): ScreenLook {
  if (screen.type === "project") {
    return {
      label: "Project",
      color: screen.data?.languages[0]?.color ?? COLOR.dim,
      icon: () => svg(ICONS.stack, 10),
    };
  }
  if (screen.type === "diff") {
    const status = FILE_STATUS[screen.file.status ?? ""] ?? MODIFIED;
    return {
      label: "File",
      color: status.color,
      icon: () => svg(ICONS.doc, 10),
      mark: () => extBadge(screen.file.path),
    };
  }
  if (screen.type === "job") {
    const state = jobOf(screen)?.job.state;
    return { label: "Job", color: state ? BUILD_STYLE[state].color : COLOR.dim, icon: () => svg(ICONS.timer, 11) };
  }
  const d = screen.data;
  switch (screen.target.kind) {
    // Grey until the state is known, so a loading sheet doesn't wear one colour
    // and then switch to another.
    case "pull": {
      const state = d?.kind === "pull" ? d.state : null;
      return {
        label: "Pull request",
        color: state ? PULL_STYLE[state].color : COLOR.dim,
        icon: () => svg(state === "merged" ? ICONS.merge : ICONS.pullRequest, 10, { stroke: 2.2 }),
      };
    }
    case "issue":
      return {
        label: "Issue",
        color: d?.kind === "issue" ? ISSUE_COLOR[d.state] : COLOR.dim,
        icon: () => svg(ICONS.issue, 10, { stroke: 2.2 }),
      };
    case "commits":
      return {
        label: screen.target.count === 1 ? "Commit" : "Commits",
        color: COLOR.blue,
        icon: () => svg(ICONS.commit, 10, { stroke: 2.2 }),
      };
    case "release":
      return { label: "Release", color: COLOR.cyan, icon: () => svg(ICONS.tag, 10, { stroke: 2.2 }) };
    case "project":
      return { label: "Project", color: COLOR.dim, icon: () => svg(ICONS.stack, 10) };
    case "run":
      return {
        label: "Run",
        color: d?.kind === "run" ? BUILD_STYLE[d.state].color : COLOR.dim,
        icon: () => svg(ICONS.timer, 11),
      };
    case "comments":
      return { label: "Comments", color: TALK_COLOR, icon: () => svg(ICONS.comment, 10, { stroke: 2.2 }) };
  }
}

/** "#12", "#4", "Commits", "v0.2.0", "CI" — what the head says while a sheet is open. */
function detailHead(screen: DetailScreen): string {
  const target = screen.target;
  switch (target.kind) {
    case "pull":
    case "issue":
      return `#${target.number}`;
    case "commits":
      return target.count === 1 ? "Commit" : "Commits";
    case "release":
      return target.tag;
    case "project":
      return target.repo;
    case "run":
      // The workflow's name: the line that opened it said it already.
      return screen.label;
    case "comments":
      return "Comments";
  }
}

/** Where a sheet sits, for the right of the panel's head. */
function detailWhere(screen: DetailScreen, login: string): string {
  const repo = repoName(screen.target.repo, login);
  // The comments are a pull request's: say which.
  return screen.target.kind === "comments" ? `#${screen.target.number} · ${repo}` : repo;
}

// ── A file's diff ─────────────────────────────────────────────────────────────
//
// The unified diff GitHub sends, drawn as the session view draws a file being
// edited: the panel is the editor, the code wears an editor's colours, one
// gutter of line numbers, and a changed line runs edge to edge with a bar of
// its colour at the left — the old line struck through, the new one under it.
// The file's name, its status and its path are in the panel's head.

const HUNK = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@ ?(.*)$/;

/** A line of a patch: the start of a hunk, or a line of code with its number on each side. */
type PatchLine =
  | { hunk: string }
  | { sign: "+" | "-" | ""; text: string; old: number | null; new: number | null };

/** Reads the unified diff GitHub sends, numbering its lines as it goes. */
function* readPatch(patch: string): Generator<PatchLine> {
  let oldLine = 0;
  let newLine = 0;
  for (const raw of patch.split("\n")) {
    const hunk = HUNK.exec(raw);
    if (hunk) {
      oldLine = Number(hunk[1]);
      newLine = Number(hunk[2]);
      yield { hunk: hunk[3] ?? "" };
      continue;
    }
    const first = raw.charAt(0);
    // "\ No newline at end of file": true of the file, nothing to read.
    if (first === "\\" || raw === "") continue;
    const sign = first === "+" || first === "-" ? first : "";
    yield {
      sign,
      text: raw.slice(1),
      old: sign === "+" ? null : oldLine++,
      new: sign === "-" ? null : newLine++,
    };
  }
}

/**
 * Which row of a patch a thread sits on — counting only the rows that are
 * lines of code — or null when the patch doesn't reach that line. A thread on
 * the left is on a line that was removed, numbered as in the old file.
 */
function threadRow(patch: string, thread: GithubThread): number | null {
  if (thread.line == null || thread.outdated) return null;
  let row = 0;
  for (const line of readPatch(patch)) {
    if ("hunk" in line) continue;
    if ((thread.side === "left" ? line.old : line.new) === thread.line) return row;
    row++;
  }
  return null;
}

function diffView(file: GithubFile, url: string, thread?: GithubThread): HTMLElement {
  if (!file.patch) {
    return h(
      "div",
      { class: "gh-sheet gh-code-empty" },
      h("div", { class: "int-empty", text: "No text diff for this file — binary, or too large for GitHub to show." }),
    );
  }

  const kind = fileKind(file.path);
  const diff = h("div", { class: "gh-diff" });
  const noted = thread ? threadRow(file.patch, thread) : null;
  let row = 0;
  let first = true;
  for (const line of readPatch(file.patch)) {
    if ("hunk" in line) {
      // Where lines were skipped: a quiet break, with the function GitHub
      // says the next lines sit in. The very first needs one only for that.
      if (!first || line.hunk) {
        diff.append(
          h("div", { class: "gh-diff-line hunk" }, h("span", { class: "n", text: "⋯" }), h("span", { class: "s" }), h("span", { class: "t", text: line.hunk })),
        );
      }
      first = false;
      continue;
    }
    // A line that is gone keeps its old number; the others have their new one.
    const el = diffLine(line.new ?? line.old, line.sign, line.text, kind);
    diff.append(el);
    // The line a thread is about, and the thread under it, as on GitHub.
    if (thread && row === noted) {
      el.classList.add("noted");
      diff.append(h("div", { class: "gh-diff-note" }, threadTalk(thread)));
    }
    row++;
  }
  // A thread with no line left in this diff heads it, and says why.
  if (thread && noted == null) {
    const why = thread.outdated
      ? "On lines that have changed since"
      : thread.line == null
        ? "On the file as a whole"
        : `On line ${thread.line}, further down than this diff goes`;
    diff.prepend(
      h("div", { class: "gh-diff-note apart" }, h("div", { class: "gh-diff-note-why", text: why }), threadTalk(thread)),
    );
  }
  return h(
    "div",
    { class: "gh-code" },
    diff,
    file.truncated
      ? h("button", { class: "gh-host", text: "The rest of this diff is on GitHub", onclick: () => void Bridge.openUrl(url) })
      : null,
  );
}

export function buildGithub(actions: ViewActions): ViewHost {
  const who = h("b", { text: "GitHub" });
  const sub = h("span", { class: "gh-sub" });
  const refreshBtn = h("button", { class: "gh-icon", title: "Refresh" }, svg(ICONS.refresh, 12, { stroke: 2 }));
  const openBtn = h(
    "button",
    {
      class: "gh-icon",
      title: "Open on GitHub",
      // Whatever is on screen, on GitHub — the way out, never the way in.
      onclick: () => {
        const s = top();
        const target = !s
          ? (githubData()?.profileUrl ?? GITHUB_HOME)
          : s.type === "project"
            ? (s.data?.url ?? `${GITHUB_HOME}/${s.fullName}`)
            : s.type === "detail"
              ? (s.data && s.data.kind !== "locked" ? s.data.url : s.url)
              : s.type === "job"
                ? (jobOf(s)?.job.url ?? s.run.url)
                : s.url;
        void Bridge.openUrl(target);
      },
    },
    svg(ICONS.arrowUpRight, 10),
  );
  // GitHub's red dot on the lists; the screen's own badge over them.
  const badge = h("span", { class: "gh-head-badge" });
  // What rides next to the tab: what happened to a file, and its lines added
  // and removed.
  const aside = h("span", { class: "gh-head-aside" });
  // Like an editor's tab: what is open on the left, where it sits on the right.
  // No ‹ here: the column's trail steps back, the island's house goes home.
  const head = h(
    "div",
    { class: "gh-head" },
    h("div", { class: "gh-tab" }, badge, who), aside, h("div", { class: "grow" }), sub, refreshBtn, openBtn,
  );
  const status = h("div", { class: "gh-status" });
  const list = h("div", { class: "gh-list" });
  // News that came in with the panel open; see drawNotice. It sits in the
  // card, over the panel and as wide as it — not in what is being read.
  const notice = h("div", { class: "gh-notice-slot" });
  const main = h("div", { class: "gh-main" }, head, status, list);

  // Mochi's column: Mochi himself (drawn by the island), whose GitHub this
  // is, then the tabs — or, deeper, the way down.
  const account = h("b", { text: "GitHub" });
  const accountSub = h("span", { text: "GitHub" });
  const trail = h("div", { class: "gh-trail" });
  const side = h("div", { class: "gh-side" }, h("div", { class: "gh-side-who" }, account, accountSub), trail);

  /**
   * A run on screen: the big Mochi works while it goes, with his crew — the
   * island's own working look. When it ends before your eyes he plays that
   * ending the way the island plays a session's: the finished roll and its
   * sparks, or the error shake, with the island's sound for it. A few seconds,
   * then he is himself again.
   */
  let ending: { state: BotStateName; until: number } | null = null;

  function wearRun() {
    if (justEnded) {
      const how = justEnded;
      justEnded = null;
      if (how !== "neutral") {
        ending = { state: how === "success" ? "finished" : "error", until: performance.now() + END_LOOK_MS };
        window.setTimeout(() => State.notify(), END_LOOK_MS + 50);
        Sound.play(how === "success" ? "finish" : "error");
      }
    }
    if (ending && performance.now() > ending.until) ending = null;
    const run = stack.length > 0 ? runOf(top()) : null;
    actions.look(ending?.state ?? (run?.state === "running" ? "working" : null));
  }

  const card = h("div", { class: "card gh-card" }, side, h("div", { class: "gh-col" }, notice, main));
  const el = h("div", { class: "view gh-view" }, card);

  /** Says which kind of screen is up: the tab's badge, and its colour on the tab. */
  function dress(look: ScreenLook | null) {
    clear(badge);
    clear(aside);
    sub.classList.remove("path");
    who.classList.remove("file");
    if (look) {
      badge.append(look.mark ? look.mark() : roundIcon(look.color, look.icon()));
      main.style.setProperty("--accent", look.color);
    } else {
      badge.append(dot(COLOR.red, 7));
      main.style.setProperty("--accent", "rgba(0,0,0,0)");
    }
  }
  dress(null);

  /**
   * With the panel open the pill is out of sight, and Mochi turning red says
   * that something happened, not what. The news gets a line of its own in the
   * card, over the panel and as wide as it — apart from what is being read,
   * and clear of the island's bar, whose middle is the notch on a MacBook:
   * what happened, the facts that go with it, and a click away, the run or
   * the pull request it is about. It leaves when the pill's badge does, or
   * once it is opened.
   */
  function drawNotice() {
    clear(notice);
    const info = State.integrations[ID];
    const news = info?.news;
    if (!info || !news) return;
    const color = news.success ? COLOR.green : COLOR.red;
    const open = news.open;
    const line = h(
      "button",
      {
        class: "gh-notice",
        onclick: () => actions.followNews(),
      },
      h("i", {}, svg(news.success ? ICONS.merge : ICONS.xmark, 11, news.success ? { stroke: 2.2 } : {})),
      h("b", { text: open?.title ?? news.label }),
      h("span", { class: "nfs" }, ...newsFacts(news)),
      h("em", { text: open?.target ? "Open" : "Dismiss" }),
    );
    line.style.setProperty("--c", color);
    notice.append(line);
  }

  function goTab(name: Tab) {
    if (tab === name) return;
    actions.blip();
    // Projects sits under Activity: its list comes from the right, as before.
    motion = name === "projects" ? "tab-right" : "tab-left";
    tab = name;
    State.notify();
  }

  /** One line of the column: a mark, a word, and where it leads, if anywhere. */
  function step(label: string, icon: Element, on: boolean, color: string | null, go: (() => void) | null) {
    const el = go
      ? h("button", { class: on ? "gh-step on" : "gh-step", onclick: go }, h("i", {}, icon), h("span", { text: label }))
      : h("div", { class: on ? "gh-step on" : "gh-step" }, h("i", {}, icon), h("span", { text: label }));
    if (color) el.style.setProperty("--c", color);
    return el;
  }

  const TABS: Record<Tab, { label: string; icon: () => SVGSVGElement }> = {
    activity: { label: "Activity", icon: () => svg(ICONS.pulse, 12, { stroke: 2 }) },
    projects: { label: "Projects", icon: () => svg(ICONS.stack, 11) },
  };

  /** Letters a name gets in the column before it is cut. */
  const STEP_LETTERS = 11;
  /** Lines the way down has room for; deeper than that, its middle folds. */
  const TRAIL_ROOM = 4;

  /**
   * "package-lock.json" → "packa….json": cut in its middle, a file keeps the
   * end that tells it from its neighbours.
   */
  function squeeze(name: string): string {
    if (name.length <= STEP_LETTERS) return name;
    const dot = name.lastIndexOf(".");
    const tail = dot > 0 && name.length - dot <= 6 ? name.slice(dot) : name.slice(-3);
    return `${name.slice(0, Math.max(1, STEP_LETTERS - tail.length - 1))}…${tail}`;
  }

  /**
   * A screen's name in the column — short, the panel's head says the rest —
   * and its whole name, for the tooltip.
   */
  function stepLabel(s: Screen): { short: string; whole: string } {
    switch (s.type) {
      case "project":
        // The owner goes: a level of the way down has no room for it.
        return { short: s.fullName.split("/")[1] ?? s.fullName, whole: s.fullName };
      case "detail": {
        const name = detailHead(s);
        return { short: name, whole: `${name} · ${s.target.repo}` };
      }
      case "diff":
        return { short: squeeze(splitPath(s.file.path).base), whole: s.file.path };
      case "job": {
        const name = jobOf(s)?.job.name ?? "Job";
        return { short: name, whole: name };
      }
    }
  }

  /**
   * The lists: both tabs, the open one lit. Deeper, the column becomes the way
   * down, drawn as one: ‹ and the tab it started from, then each level on a
   * rail, the screen on show last, lit in its colour on a plate of its own.
   * Every level above it is a click back. Past four levels the middle folds.
   */
  function drawTrail(d: GithubData | null) {
    clear(trail);
    trail.classList.toggle("deep", d != null && stack.length > 0);
    if (!d) return;
    if (stack.length === 0) {
      trail.append(
        step(TABS.activity.label, TABS.activity.icon(), tab === "activity", null, () => goTab("activity")),
        step(TABS.projects.label, TABS.projects.icon(), tab === "projects", null, () => goTab("projects")),
      );
      return;
    }
    const root = step(TABS[tab].label, svg(ICONS.chevronLeft, 11, { stroke: 2.4 }), false, null, () => {
      actions.blip();
      popTo(0);
    });
    root.title = `Back to ${TABS[tab].label}`;
    const levels = [
      root,
      ...stack.map((s, i) => {
        const look = screenLook(s);
        const last = i === stack.length - 1;
        const { short, whole } = stepLabel(s);
        const el = step(short, look.mark ? look.mark() : look.icon(), last, look.color, last ? null : () => {
          actions.blip();
          popTo(i + 1);
        });
        el.title = last ? whole : `Back to ${whole}`;
        return el;
      }),
    ];
    if (levels.length <= TRAIL_ROOM) {
      trail.append(...levels);
      return;
    }
    // The start, a mark for what is folded, and as many of the last as fit.
    const kept = TRAIL_ROOM - 2;
    const folded = step("", svg(ICONS.ellipsis, 12), false, null, null);
    folded.title = counted(levels.length - 1 - kept, "more level");
    trail.append(levels[0], folded, ...levels.slice(-kept));
  }

  /** The bottom fade says "there's more": it goes once the end is on screen. */
  const updateFade = () => {
    const more = list.scrollTop + list.clientHeight < list.scrollHeight - 2;
    list.classList.toggle("more", more);
  };
  list.addEventListener("scroll", updateFade, { passive: true });
  // The island grows and shrinks around the list as it opens and closes.
  new ResizeObserver(updateFade).observe(list);

  let refreshing = false;
  let key = "";
  let listTab: Tab | null = null;
  /** What the drawn graph shows, and what sits under it (see sync). */
  let graphKey = "";
  let below: HTMLElement | null = null;

  /** Everything under the graph — a picked day, or the recent activity — as one piece. */
  function belowSection(d: GithubData): HTMLElement {
    const section = h("div", { class: "gh-below" });
    if (day && d.contributions) {
      section.append(
        daySection(day, d.login, () => {
          actions.blip();
          unpickDay();
        }),
      );
      return section;
    }
    // What is asked of you comes before what happened; `?? []` for a snapshot
    // an older build left in the island.
    const toReview = d.toReview ?? [];
    if (toReview.length > 0) {
      section.append(heading("Waiting for your review"));
      for (const r of toReview) section.append(reviewRow(r, d.login));
      section.append(heading("Recent activity"));
    }
    if (d.activity.length === 0) {
      section.append(h("div", { class: "int-empty", text: "Nothing in the last 30 days." }));
    }
    for (const a of d.activity) section.append(activityRow(a, d.login));
    return section;
  }

  /**
   * A graph removed from under the mouse never gets its mouseleave, which
   * would leave Mochi green: every emptying of the list gives him his colour.
   */
  function clearList() {
    clear(list);
    // Only a file's code runs edge to edge; everything else keeps its margins.
    list.classList.remove("gh-edge");
    actions.tintMochi(null);
  }

  const MOTIONS = ["gh-from-right", "gh-from-left", "gh-rise", "gh-swap"];

  /** Restarts a one-off animation on an element that may have played it before. */
  function replay(el: HTMLElement, name: string) {
    el.classList.remove(...MOTIONS);
    void el.offsetWidth;
    el.classList.add(name);
  }

  /**
   * The motion the last action asked for, on what it changed: the whole list
   * (and the head's words) for a screen, the list for a tab, only what sits
   * under the graph for a day — the graph itself stays put.
   */
  function play(done: Motion | null, below: HTMLElement | null) {
    switch (done) {
      case "deeper":
      case "back":
        replay(list, done === "deeper" ? "gh-from-right" : "gh-from-left");
        replay(head, "gh-swap");
        break;
      case "tab-right":
      case "tab-left":
        replay(list, done === "tab-right" ? "gh-from-right" : "gh-from-left");
        break;
      case "day":
      case "undo-day":
        if (below) replay(below, "gh-rise");
        break;
    }
  }

  /**
   * Fresh news after a wait: the parts come in one by one, and Mochi says what
   * he thinks of them.
   */
  function arrive(content: HTMLElement, screen: Pending<unknown>, emote: BotEmoteName | null) {
    if (!screen.react) return;
    screen.react = false;
    cascade(content);
    content.classList.add("enter");
    if (emote) actions.emote(emote);
  }

  /** The screen drawn last: drawn again (a refresh), it keeps its scroll. */
  let drawn: Screen | null = null;
  /** Lines of code left above a thread's line when its diff opens on it, in px. */
  const NOTE_LEAD = 52;

  /** A screen of the stack takes the list's place; the head names what it shows. */
  function drawScreen(screen: Screen, login: string) {
    clear(status);
    listTab = null;
    const fresh = screen !== drawn;
    const scroll = fresh ? 0 : list.scrollTop;
    drawn = screen;
    clearList();
    const look = screenLook(screen);
    dress(look);
    /** "Pull request · coucou": what kind of screen, then where — the kind only once. */
    const kind = (where: string) =>
      [look.label !== who.textContent && look.label, where].filter(Boolean).join(" · ");
    if (screen.type === "job") {
      const found = jobOf(screen);
      who.textContent = found?.job.name ?? "Job";
      sub.textContent = kind(found?.run.workflow ?? "");
      if (screen.run.error) status.append(dot(COLOR.red, 5), h("span", { text: screen.run.error }));
      if (found) list.append(jobView(found.job, found.run));
      else list.append(h("div", { class: "int-empty", text: "This job is gone from the run." }));
    } else if (screen.type === "diff") {
      // As an editor heads a file: its name on the tab, its path on the right.
      who.textContent = splitPath(screen.file.path).base;
      sub.textContent = screen.file.path;
      sub.classList.add("path");
      who.classList.add("file");
      aside.append(statusWord(screen.file), plusMinus(screen.file.additions, screen.file.deletions));
      list.classList.add("gh-edge");
      list.append(diffView(screen.file, screen.url, screen.thread));
    } else if (screen.type === "project") {
      who.textContent = repoName(screen.fullName, login);
      sub.textContent = kind(screen.data?.languages[0]?.name ?? "");
      if (screen.error) status.append(dot(COLOR.red, 5), h("span", { text: screen.error }));
      if (screen.data) {
        const content = projectSheet(screen.data);
        arrive(content, screen, mood(screen.data));
        list.append(content);
      } else if (screen.waiting) {
        list.append(sheetLoader(repoName(screen.fullName, login)));
      }
    } else {
      who.textContent = detailHead(screen);
      sub.textContent = kind(detailWhere(screen, login));
      if (screen.error) status.append(dot(COLOR.red, 5), h("span", { text: screen.error }));
      if (screen.data) {
        const content = detailView(screen.data, login, screen);
        arrive(content, screen, detailMood(screen.data));
        list.append(content);
      } else if (screen.waiting) {
        list.append(sheetLoader(screen.label));
      }
    }
    list.scrollTop = scroll;
    // A diff opened from a thread opens on the thread's line, a little down
    // from the top so the lines before it say where it sits.
    const noted = fresh ? list.querySelector<HTMLElement>(".gh-diff-line.noted") : null;
    if (noted) {
      list.scrollTop = noted.getBoundingClientRect().top - list.getBoundingClientRect().top - NOTE_LEAD;
    }
    updateFade();
  }

  refreshBtn.addEventListener("click", async () => {
    const s = top();
    const own = s ? fetched(s) : null;
    if (refreshing || own?.loading) return;
    actions.blip();
    if (own?.type === "project") {
      void loadProject(own, true);
      return;
    }
    if (own?.type === "detail") {
      void loadDetail(own, true);
      return;
    }
    refreshing = true;
    State.notify();
    const started = performance.now();
    // Resolves once Rust has finished — the new data has already arrived by then.
    await Bridge.refreshIntegration(ID);
    const left = MIN_SPIN_MS - (performance.now() - started);
    if (left > 0) await new Promise((r) => window.setTimeout(r, left));
    refreshing = false;
    State.notify();
  });

  return {
    el,
    sync() {
      const info = State.integrations[ID];
      const d = githubData();
      const configured = info?.configured !== false;
      const error = info?.error ?? null;

      const s = top();
      const own = s ? fetched(s) : null;
      refreshBtn.classList.toggle("spin", refreshing || own?.loading === true);
      // A diff is part of the sheet under it: nothing of its own to refresh.
      refreshBtn.style.display = configured && s?.type !== "diff" ? "" : "none";
      armLive();
      wearRun();
      // Once this draw is done: the Mochis whose rows it dropped can go.
      queueMicrotask(dismissCrew);

      // Rebuilding the rows between a mouse-down and its mouse-up would swallow
      // the click, so only rebuild when something they show has changed.
      const news = info?.news;
      const next = [configured, error, d?.fetchedAt, d?.login, tab, stamp, news?.label, news?.detail].join("~");
      if (next === key) return;
      key = next;

      // Taken now: whatever draws next is what the action was about.
      const done = motion;
      motion = null;

      drawNotice();

      // Under Mochi, as under a Claude Code session's: who, then through what.
      account.textContent = d && configured ? d.login : "GitHub";
      accountSub.textContent = !configured ? "Not connected" : d ? "GitHub" : "Loading…";

      if (s && d && configured) {
        drawScreen(s, d.login);
        drawTrail(d);
        play(done, null);
        return;
      }

      dress(null);
      drawTrail(d && configured ? d : null);
      drawn = null;
      who.textContent = d && configured ? TABS[tab].label : "GitHub";
      sub.textContent = "";

      clear(status);
      if (!configured) {
        status.append(
          dot(COLOR.red, 5),
          h("span", { text: "No token yet" }),
          h("button", {
            class: "link-btn",
            style: "color:var(--dim-2)",
            text: "Settings…",
            onclick: () => actions.openSettingsWindow(),
          }),
        );
      } else if (error) {
        // What's below is the last good answer: say why, and how old it is.
        const when = d ? timeAgo(d.fetchedAt) : "";
        const age = when && when !== "just now" ? ` · data from ${when} ago` : "";
        status.append(dot(COLOR.red, 5), h("span", { text: `${error}${age}` }));
      } else if (!d) {
        status.append(h("span", { text: "Loading…" }));
      }

      // A refresh lands while the list may be scrolled: stay where the reader was,
      // unless they just switched tabs.
      const freshTab = tab !== listTab;
      const scroll = freshTab ? 0 : list.scrollTop;
      const sweep = freshTab || sweepNext;
      sweepNext = false;
      listTab = tab;

      // A picked day loads in two or three draws (the loader, then the data).
      // Rebuilding the graph on each would cut its fade short: while nothing
      // the graph shows has changed, only what is under it is redrawn.
      const nextGraphKey = d && tab === "activity" ? [d.fetchedAt, d.login, day?.index ?? ""].join("|") : "";
      if (!sweep && nextGraphKey && nextGraphKey === graphKey && below?.isConnected && d) {
        const fresh = belowSection(d);
        below.replaceWith(fresh);
        below = fresh;
        list.scrollTop = scroll;
        updateFade();
        play(done, below);
        return;
      }
      graphKey = nextGraphKey;

      clearList();
      below = null;
      if (!d || !configured) {
        updateFade();
        return;
      }
      if (tab === "projects") {
        if (d.repos.length === 0) {
          list.append(h("div", { class: "int-empty", text: "No repositories yet." }));
        }
        for (const repo of d.repos) {
          list.append(repoRow(repo, d.login, () => openProject(repo.fullName)));
        }
      } else {
        // The year first, then what happened lately — or on the picked day.
        const picked = day && d.contributions ? day : null;
        if (d.contributions) {
          list.append(
            contributionGraph(d.contributions, {
              sweep,
              tint: actions.tintMochi,
              picked: picked?.index ?? null,
              settle: done === "day" ? "picked" : done === "undo-day" ? "unpicked" : null,
              onPick: (index, date) => {
                actions.blip();
                pickDay(index, date);
              },
            }),
          );
          // Mochi wears the picked day's colour for as long as it is picked.
          if (picked) actions.tintMochi(mochiShade(d.contributions, picked.index));
        }
        below = belowSection(d);
        list.append(below);
      }
      list.scrollTop = scroll;
      updateFade();
      play(done, below);
    },
  };
}

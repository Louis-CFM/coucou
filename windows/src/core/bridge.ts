// Thin wrapper over the Tauri commands/events. Every call is a no-op when the
// page is opened in a plain browser, so the island can be iterated on with
// `npm run dev` alone.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import type { Settings } from "./state";

export const IS_TAURI =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!IS_TAURI) return null;
  try {
    return await invoke<T>(cmd, args);
  } catch (err) {
    console.error(`[coucou] ${cmd} failed`, err);
    return null;
  }
}

export interface BootInfo {
  settings: Settings;
  /** Logical screen rect of the monitor the island lives on. */
  screen: { x: number; y: number; width: number; height: number; scale: number };
  version: string;
  hookPath: string;
  /** False where the OS has no global cursor (Wayland): see Island.followPageCursor. */
  cursorPoll: boolean;
}

export const Bridge = {
  boot: () => call<BootInfo>("boot"),

  saveSettings: (settings: Settings) => call<void>("save_settings", { settings }),

  /** Shrink the window down to the invisible wake strip (hidden) or back to full. */
  setCollapsed: (collapsed: boolean) => call<void>("set_collapsed", { collapsed }),

  /**
   * Pushes the island shape in window coordinates. Rust flips click-through from
   * its own cursor poll, so the flag is never a frame behind a click.
   */
  setIslandRect: (x: number, y: number, width: number, height: number) =>
    call<void>("set_island_rect", { x, y, width, height }),

  /** Give the window keyboard focus (chat field) and take it away again. */
  focusWindow: (focused: boolean) => call<void>("focus_window", { focused }),

  reposition: () => call<void>("reposition"),

  openUrl: (url: string) => call<void>("open_url", { url }),

  /** "Open terminal" → opens the folder in VS Code when `code` is on PATH. */
  openInVSCode: (path: string | null) => call<boolean>("open_in_vscode", { path }),
  /** Brings the Claude desktop app forward. */
  openClaudeApp: () => call<void>("open_claude_app"),

  quit: () => call<void>("quit_app"),

  openSettingsWindow: () => call<void>("open_settings_window"),

  /** Writes to %LOCALAPPDATA%\Coucou\coucou.log, next to the Rust lines. */
  log: (message: string) => call<void>("log_line", { message }),

  // ── Claude Code hooks ─────────────────────────────────────────────────────
  hooksStatus: () => call<HookStatus>("hooks_status"),
  /** Diff to show before anything is written. `install: false` previews removal. */
  hooksPreview: (install: boolean) => callOrThrow<HookPreview>("hooks_preview", { install }),
  /**
   * Writes ~/.claude/settings.json — only ever after an explicit click, and only
   * when the file still matches the preview the user looked at.
   */
  hooksApply: (install: boolean, fingerprint: string) =>
    callOrThrow<string>("hooks_apply", { install, fingerprint }),

  approvalDecision: (requestId: string, decision: "allow" | "deny" | "skip") =>
    call<void>("approval_decision", { requestId, decision }),
  /** "The card is up" — until this lands the relay only waits a moment. */
  approvalAck: (requestId: string) => call<void>("approval_ack", { requestId }),
  /** "Nobody can act on this" — Claude Code asks in the terminal right away. */
  approvalDecline: (requestId: string) => call<void>("approval_decline", { requestId }),
  /** The answers to a question Claude asked, keyed by the question's own words. */
  approvalAnswer: (requestId: string, answers: Record<string, string>) =>
    call<void>("approval_answer", { requestId, answers }),

  // ── Chat, files, secrets ──────────────────────────────────────────────────
  /** One chat turn. The API key and any file bytes never leave Rust. */
  chatSend: (query: string, context: ChatContext | null) =>
    callOrThrow<{ text: string }>("chat_send", { query, context }),
  chatReset: () => call<void>("chat_reset"),
  /** Copies a dropped file into the inbox. */
  ingestFile: (path: string) => callOrThrow<DroppedFile>("ingest_file", { path }),
  /** Only ever tells you whether a key exists — never its value. */
  secretPresent: (key: string) => call<boolean>("secret_present", { key }),
  secretSet: (key: string, value: string) => callOrThrow<void>("secret_set", { key, value }),
  secretClear: (key: string) => callOrThrow<void>("secret_clear", { key }),

  // ── Integrations ──────────────────────────────────────────────────────────
  refreshIntegration: (id: string) => call<void>("refresh_integration", { id }),
  /** Opens the configured n8n instance in the browser. */
  openN8n: () => call<void>("open_n8n"),

  /** Tray → Pause. Stops the integration pollers, not just the island. */
  setPaused: (paused: boolean) => call<void>("set_paused", { paused }),

  // ── GitHub ────────────────────────────────────────────────────────────────
  /** Settings → Test connection. Runs on the stored token; the token never comes back. */
  githubTest: () => callOrThrow<GithubAccount>("github_test"),
  /** A project's sheet, fetched on the click. `force` skips the minute of cache. */
  githubProject: (fullName: string, force: boolean) =>
    callOrThrow<GithubProject>("github_project", { fullName, force }),
  /** What was done on one day of the graph, between two local midnights (ISO). */
  githubDay: (from: string, to: string, today: boolean) =>
    callOrThrow<GithubDay>("github_day", { from, to, today }),
  /** The sheet behind a line of activity. `target` goes back exactly as Rust sent it. */
  githubDetail: (target: GithubTarget, force: boolean) =>
    callOrThrow<GithubDetail>("github_detail", { target, force }),
};

/** What a line of activity leads to — the Target enum in github_detail.rs. */
export type GithubTarget =
  | { kind: "pull"; repo: string; number: number }
  | { kind: "issue"; repo: string; number: number }
  | {
      kind: "commits"; repo: string; head: string | null; count: number | null;
      branch: string | null; author: string | null; from: string | null; to: string | null;
    }
  | { kind: "release"; repo: string; tag: string }
  | { kind: "project"; repo: string }
  | { kind: "run"; repo: string; id: number }
  | { kind: "comments"; repo: string; number: number };

export interface GithubFile {
  path: string;
  /** added, modified, removed, renamed… */
  status: string | null;
  additions: number;
  deletions: number;
  /** The unified diff; null for a binary file or one GitHub won't diff. */
  patch: string | null;
  /** The patch was cut short; the rest is on GitHub. */
  truncated: boolean;
}

export interface GithubLabel {
  name: string;
  /** "#rrggbb". */
  color: string;
}

export interface GithubPullDetail {
  kind: "pull";
  repo: string;
  number: number;
  title: string;
  url: string;
  state: "open" | "draft" | "merged" | "closed";
  author: string | null;
  base: string | null;
  head: string | null;
  additions: number;
  deletions: number;
  changedFiles: number;
  commits: number;
  comments: number;
  /** Threads of comments on the lines of code. */
  threads: number;
  review: "approved" | "changes requested" | "review required" | null;
  reviewers: { login: string; state: "approved" | "changes requested" | "commented" | "dismissed" }[];
  labels: GithubLabel[];
  files: GithubFile[];
  createdAt: string | null;
  mergedAt: string | null;
  mergedBy: string | null;
  closedAt: string | null;
  ci: GithubBuild | null;
  missing: string[];
}

export interface GithubIssueDetail {
  kind: "issue";
  repo: string;
  number: number;
  title: string;
  url: string;
  state: "open" | "completed" | "not planned" | "closed";
  author: string | null;
  body: string | null;
  labels: GithubLabel[];
  assignees: string[];
  comments: number;
  createdAt: string | null;
  closedAt: string | null;
}

export interface GithubCommitsDetail {
  kind: "commits";
  repo: string;
  branch: string | null;
  /** How many the push or the day counted; `commits` may hold fewer. */
  total: number | null;
  /** Newest first. */
  commits: { sha: string; id: string; message: string; author: string | null; at: string | null; url: string }[];
  /** What the newest commit changed. */
  additions: number | null;
  deletions: number | null;
  files: GithubFile[];
  ci: GithubBuild | null;
  url: string;
  missing: string[];
}

export interface GithubReleaseDetail {
  kind: "release";
  repo: string;
  tag: string;
  name: string;
  url: string;
  body: string | null;
  author: string | null;
  publishedAt: string | null;
  prerelease: boolean;
  assets: { name: string; downloads: number; size: number }[];
  downloads: number;
}

/**
 * A step of a job, a job of a run, a run: its colour (`state`), its word
 * (`outcome`: passed, failed, running, queued, cancelled, skipped…), and when
 * it started and ended — how long it took is worked out from those.
 */
export interface GithubTimed {
  state: GithubBuild["state"];
  outcome: string;
  /** Null while it waits for its turn. */
  startedAt: string | null;
  /** Null while it runs. */
  endedAt: string | null;
}

export interface GithubStep extends GithubTimed {
  name: string;
}

export interface GithubJob extends GithubTimed {
  id: number;
  name: string;
  /** The job's page on GitHub, with its logs. */
  url: string;
  /** The machine it asked for, e.g. "ubuntu-latest". */
  runner: string | null;
  steps: GithubStep[];
}

export interface GithubRunDetail extends GithubTimed {
  kind: "run";
  repo: string;
  id: number;
  workflow: string;
  title: string | null;
  branch: string | null;
  /** push, pull_request, schedule, workflow_dispatch… */
  event: string | null;
  actor: string | null;
  /** 2 and up for a re-run. */
  attempt: number;
  url: string;
  jobs: GithubJob[];
  /** Jobs of the run beyond the ones carried. */
  moreJobs: number;
}

/** Something somebody wrote on a pull request. */
export interface GithubRemark {
  /** Null for an account that is gone. */
  author: string | null;
  /** Plain text, its lines kept; empty for a review that only gave a verdict. */
  body: string;
  /** The text was cut short; the whole of it is at `url`. */
  cut: boolean;
  at: string | null;
  url: string;
}

/** Comments on one place in the code, and the replies under them. */
export interface GithubThread {
  path: string;
  /** Null on a whole file, or once the code under it has changed. */
  line: number | null;
  /** "left" on a line that was removed. */
  side: "left" | "right";
  resolved: boolean;
  outdated: boolean;
  /** The lines it is about, numbered as in the file. */
  code: { number: number | null; sign: "+" | "-" | ""; text: string }[];
  remarks: GithubRemark[];
  /** Replies beyond the ones carried. */
  more: number;
}

export type GithubEntry =
  | ({ kind: "description" | "comment" } & GithubRemark)
  | ({ kind: "review"; state: "approved" | "changes requested" | "commented" | "dismissed" } & GithubRemark)
  | ({ kind: "thread" } & GithubThread);

/** What was said on a pull request, oldest first. To read only. */
export interface GithubCommentsDetail {
  kind: "comments";
  repo: string;
  number: number;
  title: string;
  url: string;
  entries: GithubEntry[];
  /** Older ones than these are on GitHub. */
  earlier: boolean;
}

/** A line's sheet, or the permission the token lacks to read it. */
export type GithubDetail =
  | GithubPullDetail
  | GithubIssueDetail
  | GithubCommitsDetail
  | GithubReleaseDetail
  | GithubRunDetail
  | GithubCommentsDetail
  | { kind: "locked"; permission: string };

/** A clicked day of the contribution graph — the Day struct in github.rs. */
export interface GithubDay {
  items: {
    kind: GithubActivityKind | "review";
    /** "owner/name". */
    repo: string;
    title: string;
    detail: string | null;
    url: string;
    target: GithubTarget | null;
  }[];
  /** Contributions that day in repositories the token can't see into. */
  privateCount: number;
}

/** The sheet behind a click on a project — the Project struct in github.rs. */
export interface GithubProject {
  fullName: string;
  url: string;
  description: string | null;
  homepage: string | null;
  private: boolean;
  createdAt: string | null;
  stars: number;
  forks: number;
  /** Largest first, the tail folded into "Other" (color null). */
  languages: { name: string; color: string | null; share: number }[];
  /** Newest first, up to eight — the CI streak. */
  runs: GithubRun[];
  pull: GithubPull | null;
  deploy: GithubDeploy | null;
  /** The permissions the token lacks to read some of this, as GitHub names them. */
  missing: string[];
}

export interface GithubRun {
  id: number;
  state: GithubBuild["state"];
  workflow: string;
  branch: string | null;
  /** The commit or pull request the run is about. */
  title: string | null;
  actor: string | null;
  url: string;
  startedAt: string | null;
  updatedAt: string;
}

export interface GithubPull {
  number: number;
  title: string;
  url: string;
  state: "open" | "draft" | "merged" | "closed";
  author: string | null;
  additions: number;
  deletions: number;
  changedFiles: number;
  review: "approved" | "changes requested" | "review required" | null;
  comments: number;
  /** Merged at, or last update. */
  at: string;
}

export interface GithubDeploy {
  environment: string;
  state: "success" | "failure" | "running" | "inactive";
  url: string | null;
  creator: string | null;
  sha: string | null;
  at: string;
}

/** `State.integrations.integration_github.data` — the Snapshot in github.rs. */
export interface GithubData {
  login: string;
  profileUrl: string;
  totalStars: number;
  /** Newest first. */
  activity: GithubActivity[];
  /** Most recently pushed first. */
  repos: GithubRepo[];
  /** The year behind the contribution graph. */
  contributions: GithubContributions | null;
  /** Unix ms of the last complete refresh. */
  fetchedAt: number;
}

export interface GithubContributions {
  total: number;
  /** First day, "YYYY-MM-DD"; one entry per day from there, today last. */
  start: string;
  counts: number[];
  /** GitHub's quartiles: 0 (none) to 4 (busiest). */
  levels: number[];
}

export interface GithubRepo {
  /** "owner/name". */
  fullName: string;
  url: string;
  private: boolean;
  language: string | null;
  /** GitHub's colour for the language. */
  languageColor: string | null;
  stars: number;
  openPrs: number;
  /** ISO 8601. */
  pushedAt: string | null;
  /** The newest Actions run on any branch; null when there is none to read. */
  build: GithubBuild | null;
}

export interface GithubBuild {
  id: number;
  state: "success" | "failure" | "running" | "neutral";
  /** The workflow's name, e.g. "CI". */
  workflow: string;
  branch: string | null;
  url: string;
  /** ISO 8601. */
  at: string;
}

export type GithubActivityKind =
  | "push" | "pr_opened" | "pr_merged" | "pr_closed"
  | "issue_opened" | "issue_closed" | "release" | "create";

export interface GithubActivity {
  kind: GithubActivityKind;
  /** "owner/name". */
  repo: string;
  title: string;
  /** "#12", a branch, a tag. */
  detail: string | null;
  url: string;
  /** ISO 8601. */
  at: string;
  /** The sheet a click opens in the panel; null: straight to GitHub. */
  target: GithubTarget | null;
}

export interface GithubAccount {
  login: string;
  name: string | null;
  /** GitHub's `github-authentication-token-expiration` header, as sent. Null: no expiry. */
  expiresAt: string | null;
  /** One line per thing the panel needs, so a missing permission is named. */
  checks: { label: string; ok: boolean; note: string | null }[];
}

/**
 * One thing a news card says under its title, with what it is, so it is drawn
 * as that: a project, who did it (`verb`: "merged by"), a size in lines, a
 * count of files, a branch, the step a build broke at, a commit's title.
 */
export interface NewsFact {
  kind: "repo" | "by" | "diff" | "files" | "branch" | "step" | "commit";
  text?: string;
  verb?: string;
  additions?: number;
  deletions?: number;
}

/** Something that just happened in an integration: the pill's badge and sound. */
export interface IntegrationNews {
  success: boolean;
  label: string;
  detail: string | null;
  /**
   * What the island can say and open for it (GitHub): a title and a line of
   * facts for the card — the step that broke, who merged — and the run or
   * the pull request to go to.
   */
  open?: {
    target?: GithubTarget; label?: string; url?: string; title?: string; facts?: NewsFact[];
    /** What kind of news this is, as the card says it: "pull request opened". */
    says?: string;
  };
}

export interface IntegrationUpdate {
  id: string;
  data: Record<string, unknown>;
  error: string | null;
  event: IntegrationNews | null;
}

export type ChatContext =
  | { kind: "file"; name: string; path: string }
  | { kind: "window"; appName: string; title: string; url?: string };

export interface DroppedFile {
  name: string;
  path: string;
  size: number;
}

export interface HookStatus {
  installed: boolean;
  settingsPath: string;
  hookPath: string;
  hookReady: boolean;
}

export interface HookPreview {
  diff: string;
  backup: string;
  settingsPath: string;
  /** Hand back to hooksApply so only the reviewed diff is ever written. */
  fingerprint: string;
}

/** Same as `call`, but surfaces the error so the UI can show what went wrong. */
async function callOrThrow<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (!IS_TAURI) throw new Error("not running inside Coucou");
  return invoke<T>(cmd, args);
}

export type BridgeEvent =
  | { name: "cursor"; payload: { x: number; y: number } }
  | { name: "tray"; payload: string }
  | { name: "hook"; payload: Record<string, unknown> }
  | { name: "screen-changed"; payload: null };

export interface DragDropPayload {
  type: "enter" | "over" | "drop" | "leave";
  paths?: string[];
}

/** Files dragged onto the island. Only reaches us when the window takes the mouse. */
export async function onDragDrop(handler: (e: DragDropPayload) => void) {
  if (!IS_TAURI) return () => {};
  return getCurrentWebview().onDragDropEvent((event) => {
    handler(event.payload as DragDropPayload);
  });
}

export async function onEvent<T>(name: string, handler: (payload: T) => void) {
  if (!IS_TAURI) return () => {};
  return listen<T>(name, (e) => handler(e.payload));
}

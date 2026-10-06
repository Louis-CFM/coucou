// Claude Code hook events → island state.
// Port of HookServer.processEvent / processPermissionRequest from the macOS app.
// Difference from macOS: no terminal filter. On Windows the hook fires from any
// client — the Claude desktop app, VS Code, Windows Terminal, PowerShell… — and
// all of them are handled.
//
// Windows goes a step further than the Swift app on two things, both read from
// what the hooks already carry: what Claude is doing — each file it changes,
// what it said to end its turn (the session panel) — and the questions it asks
// with its question tool, answered on the island.

import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import {
  CLAUDE_ID, QUESTION_TOOL, SESSION_UNNAMED, State, TURN_DONE, newSession, newStep,
  type ChangedFile, type ClaudeClient, type ClaudeSession, type Question, type StepKind, type StepResult,
} from "../core/state";
import type { IslandViewName } from "../core/layout";
import type { Island } from "./island";

/**
 * By session: clears its request if no decision was made before the hook gave
 * up. Coucou answers within 108 s or not at all; after that the terminal has
 * taken over and the card would be lying.
 */
const pendingTimeouts = new Map<string, number>();
const PENDING_MS = 110_000;

export interface HookPayload {
  hook_event_name?: string;
  request_id?: string;
  session_id?: string;
  cwd?: string;
  message?: string;
  /** UserPromptSubmit carries `prompt`; `message` belongs to Notification/Stop. */
  prompt?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  /** Optional agent tag: lowercase, digits and hyphens, ≤ 24 chars. */
  coucou_agent?: string;
  /** CLAUDE_CODE_ENTRYPOINT and TERM_PROGRAM, added by coucou-hook. */
  entrypoint?: string;
  term_program?: string;
  /** What an edit tool did to its file — added by coucou-hook to PostToolUse. */
  change?: { patch: string; additions: number; deletions: number; truncated: boolean; created: boolean };
  /** A few lines of what a tool gave back — added by coucou-hook to PostToolUse. */
  result?: StepResult;
  /** On a PostToolUseFailure: what went wrong. */
  error?: string;
  /** What was picked for each question of Claude's question tool — added by coucou-hook to PostToolUse. */
  answers?: Record<string, string>;
  /** What an edit asking for permission would do — added by coucou-hook to PermissionRequest. */
  proposal?: { patch: string; additions: number; deletions: number; truncated: boolean; created: boolean };
  /** The conversation's title, read by coucou-hook from the session's transcript. */
  session_title?: string;
  /** On a Stop: what Claude said to end its turn. */
  last_message?: string;
}

/** Sessions followed at once: as many as the island has tabs for. */
const MAX_SESSIONS = 4;
/** Files kept for a session, and edits kept for a file. */
const MAX_FILES = 40;
const MAX_EDITS = 12;
/**
 * Lines kept of a session's journal. It empties as it fills: past that, the
 * oldest line goes for each new one, so a session that runs all day costs no
 * more than one that just started.
 */
const MAX_STEPS = 80;
/** Lines kept of what a session did; past that the older half goes. */
const MAX_LINES = 200;
/** Such a line is this long at most. */
const LINE_CHARS = 60;
/** How long a session that just finished says so before it goes back to rest. */
const FINISHED_MS = 5_200;
/** The id of a session whose hooks carry none. */
const ANONYMOUS = "session";

/** What each tool does, as far as showing it goes; one not listed is "other". */
const STEP_KINDS: Record<string, StepKind> = {
  Read: "read", NotebookRead: "read",
  Edit: "edit", Write: "edit", MultiEdit: "edit", NotebookEdit: "edit",
  Bash: "command", PowerShell: "command",
  Grep: "search", Glob: "search", WebSearch: "search", ToolSearch: "search",
};

/** The fields of a tool's input that say what it is at, the most telling first. */
const TARGET_FIELDS = ["command", "file_path", "notebook_path", "path", "pattern", "query", "url", "description"] as const;
const PATH_FIELDS: ReadonlySet<string> = new Set(["file_path", "notebook_path", "path"]);

/** What a tool is at: its file by its path in the session's folder, its command, what it looks for. */
function stepTarget(input: Record<string, unknown>, cwd: string): string | null {
  for (const field of TARGET_FIELDS) {
    const value = input[field];
    if (typeof value === "string" && value.trim()) return PATH_FIELDS.has(field) ? sessionPath(value, cwd) : value.trim();
  }
  return null;
}

/** One more line in the session's journal. */
function log(session: ClaudeSession, step: ReturnType<typeof newStep>) {
  session.steps.push(step);
  if (session.steps.length > MAX_STEPS) session.steps.shift();
  return step;
}

/** The step of a tool still going, the last one started. */
function goingStep(session: ClaudeSession, tool: string) {
  return [...session.steps].reverse().find((s) => s.tool === tool && s.state === "running") ?? null;
}

/** A tool starts: one more step, going. */
function startStep(session: ClaudeSession, tool: string, input: Record<string, unknown>, cwd: string) {
  const step = log(session, newStep(tool, STEP_KINDS[tool] ?? "other", stepTarget(input, cwd)));
  if (tool === QUESTION_TOOL) step.questions = questionsOf(input);
}

/** A tool ends: its last step still going takes the outcome, and what the tool gave back. */
function endStep(session: ClaudeSession, payload: HookPayload, state: "done" | "failed") {
  const step = goingStep(session, payload.tool_name ?? "Tool");
  if (!step) return;
  step.state = state;
  step.at = Date.now();
  step.patch = payload.change?.patch ?? null;
  step.result = payload.result ?? (payload.error ? { text: payload.error, start: null, truncated: false, tail: false } : null);
  if (payload.answers) step.answers = payload.answers;
  // It ran, so whoever was asked said yes — here or in Claude Code.
  if (step.permission === "asked") step.permission = state === "done" ? "allowed" : "denied";
}

/** The turn ends: nothing is going any more, and the journal closes on what Claude said. */
function closeSteps(session: ClaudeSession, answer: string | null) {
  for (const step of session.steps) if (step.state === "running") step.state = "done";
  log(session, newStep(TURN_DONE, "reply", answer));
}

/** One more line of what the session did. */
function say(session: ClaudeSession, line: string) {
  session.lines.push(line);
  if (session.lines.length > MAX_LINES) session.lines.splice(0, MAX_LINES / 2);
}

/** How the Agent SDK names itself as an entry point: "sdk-ts", "sdk-py", "sdk-cli". */
const SDK_ENTRYPOINT = "sdk";

/**
 * A session started by a program rather than a person — a review a plugin runs
 * on each commit, a script. It sends the same hooks from the same folder, and
 * followed like any other it would take the island away from the conversation
 * the user is in, steps, title and all.
 */
function isAutomated(payload: HookPayload): boolean {
  return (payload.entrypoint ?? "").toLowerCase().startsWith(SDK_ENTRYPOINT);
}

function clientOf(payload: HookPayload): ClaudeClient {
  const entry = (payload.entrypoint ?? "").toLowerCase();
  if (entry.includes("desktop")) return "desktop";
  if (entry.includes("vscode") || (payload.term_program ?? "").toLowerCase().includes("vscode")) return "vscode";
  return "terminal";
}

const waits = (session: ClaudeSession) => session.approval != null || session.question != null;

/** No turn under way, and nothing asked: the session is where its last turn left it. */
const AT_REST: ReadonlySet<string> = new Set(["idle", "finished", "error", "sleeping"]);
const resting = (session: ClaudeSession) => AT_REST.has(session.state) && !waits(session);

/** The session an event comes from, told what the event says of it. A new one gets a place. */
function sessionOf(island: Island, payload: HookPayload): ClaudeSession {
  const id = payload.session_id || ANONYMOUS;
  let session = State.sessions.find((s) => s.id === id);
  if (!session) {
    session = newSession(id);
    State.sessions.push(session);
    makeRoom(island, session);
  }
  session.client = clientOf(payload);
  if (payload.session_title) session.title = payload.session_title;
  if (payload.cwd) {
    session.cwd = payload.cwd;
    session.project = aliasProjectName(lastPathComponent(payload.cwd) || SESSION_UNNAMED);
  }
  session.heardAt = Date.now();
  return session;
}

/**
 * One session too many: the one that goes is at rest if any is, and the one
 * heard from longest ago. Never the one in front, the one that just came, or
 * one that is waiting for an answer.
 */
function makeRoom(island: Island, newcomer: ClaudeSession) {
  while (State.sessions.length > MAX_SESSIONS) {
    const old = State.sessions
      .filter((s) => s !== newcomer && s.id !== State.frontId && !waits(s))
      .sort((a, b) => Number(resting(b)) - Number(resting(a)) || a.heardAt - b.heardAt)[0];
    if (!old) return;
    forget(island, old);
  }
}

/** A session is over, or gave its place: nothing of it is kept. */
function forget(island: Island, session: ClaudeSession) {
  const at = State.sessions.indexOf(session);
  if (at < 0) return;
  const request = (session.approval ?? session.question)?.requestId;
  if (request) void Bridge.approvalDecline(request);
  stopWaiting(session);
  State.sessions.splice(at, 1);
  State.changes.delete(session.id);
  if (session.id !== State.frontId) return;
  // It was in front: the one heard from last takes its place.
  const next = [...State.sessions].sort((a, b) => b.heardAt - a.heardAt)[0];
  State.bringForward(next?.id ?? "");
  island.afterRequest(onCard());
}

/** True while the island shows a request's card. */
const onCard = () => State.view === "approval" || State.view === "question";

/** The views that are about the session in front: it is not changed under them. */
const ABOUT_FRONT: ReadonlySet<IslandViewName> = new Set(["session", "finished", "error", "approval", "question"]);
/** The events that say a session is being worked in. */
const WORK_EVENTS: ReadonlySet<string> = new Set(["SessionStart", "UserPromptSubmit", "PreToolUse"]);

/**
 * Whether the session an event comes from takes the front. The island stays on
 * the session it shows for as long as that one is at work or being looked at:
 * another one takes its place when it has nothing going on, or to ask for
 * something — unless the one in front is itself waiting for an answer, and
 * then the request waits its turn.
 */
function takesFront(session: ClaudeSession, event: string): boolean {
  const front = State.session;
  if (!front.id) return true;
  if (front === session || waits(front)) return false;
  if (event === "PermissionRequest") return true;
  const watched = State.mode === "expanded" && ABOUT_FRONT.has(State.view);
  return WORK_EVENTS.has(event) && resting(front) && !watched;
}

/** "C:\\work\\app\\src\\a.ts" in "C:\\work\\app" → "src/a.ts". Outside the folder, the whole path. */
function sessionPath(file: string, cwd: string): string {
  const path = file.replace(/\\/g, "/");
  const root = cwd.replace(/\\/g, "/").replace(/\/+$/, "");
  return root && path.toLowerCase().startsWith(`${root.toLowerCase()}/`) ? path.slice(root.length + 1) : path;
}

/** One more edit to a file: the file moves to the top of the session's changes. */
function recordChange(session: ClaudeSession, payload: HookPayload) {
  const change = payload.change;
  const file = payload.tool_input?.file_path;
  if (!change || typeof file !== "string") return;
  const path = sessionPath(file, payload.cwd ?? "");
  const files = State.changes.get(session.id) ?? [];
  const at = files.findIndex((f) => f.path === path);
  const entry: ChangedFile =
    at >= 0 ? files.splice(at, 1)[0] : { path, created: change.created, additions: 0, deletions: 0, edits: [], at: 0 };
  entry.edits.push({
    patch: change.patch, additions: change.additions, deletions: change.deletions,
    truncated: change.truncated, at: Date.now(),
  });
  if (entry.edits.length > MAX_EDITS) entry.edits.shift();
  entry.additions += change.additions;
  entry.deletions += change.deletions;
  entry.at = Date.now();
  files.unshift(entry);
  if (files.length > MAX_FILES) files.pop();
  State.changes.set(session.id, files);
}

/** The question tool's input as the island shows it — null when it is not one it can answer. */
function questionsOf(input: Record<string, unknown>): Question[] | null {
  const raw = input.questions;
  if (!Array.isArray(raw) || raw.length === 0) return null;
  const questions: Question[] = [];
  for (const q of raw as Record<string, unknown>[]) {
    const options = Array.isArray(q?.options) ? (q.options as Record<string, unknown>[]) : [];
    if (typeof q?.question !== "string" || options.some((o) => typeof o?.label !== "string")) return null;
    questions.push({
      question: q.question,
      header: typeof q.header === "string" ? q.header : null,
      options: options.map((o) => ({
        label: o.label as string,
        description: typeof o.description === "string" ? o.description : null,
      })),
      multiSelect: q.multiSelect === true,
    });
  }
  return questions;
}

/** The relay's wait for this session's request is no longer the island's to time. */
function stopWaiting(session: ClaudeSession) {
  const timeout = pendingTimeouts.get(session.id);
  if (timeout != null) window.clearTimeout(timeout);
  pendingTimeouts.delete(session.id);
}

/**
 * A session's request is no longer needed: it was answered in Claude Code
 * itself, or the relay stopped waiting. The island lets go of it.
 */
function dropPending(island: Island, session: ClaudeSession) {
  stopWaiting(session);
  if (!waits(session)) return;
  session.approval = null;
  session.question = null;
  session.state = "working";
  if (session.news === "approval") session.news = null;
  if (session.id === State.frontId) island.afterRequest(onCard());
}

/** True when this event says the tool the session's request is about has run: someone answered elsewhere. */
function answeredElsewhere(session: ClaudeSession, payload: HookPayload): boolean {
  if (!waits(session)) return false;
  return payload.tool_name === (session.question ? QUESTION_TOOL : session.approval?.tool);
}

/** Same rule as HookServer.validateAgent on macOS. "claude" is reserved. */
function validateAgent(raw: string | undefined): string | null {
  if (!raw || raw.length > 24 || raw === "claude") return null;
  if (!/^[a-z0-9-]+$/.test(raw)) return null;
  return raw;
}

const FALLBACK_COLORS = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"];

function agentColor(name: string): string {
  let h = 0;
  for (let i = 0; i < name.length; i++) {
    h = (Math.imul(31, h) + name.charCodeAt(i)) | 0;
  }
  return FALLBACK_COLORS[Math.abs(h) % FALLBACK_COLORS.length];
}

const PROJECT_ALIASES: Record<string, string> = {
  "notch-buddy": "Notch Buddy",
  notchbuddy: "Notch Buddy",
  notch_buddy: "Notch Buddy",
};

function aliasProjectName(name: string): string {
  return PROJECT_ALIASES[name.toLowerCase()] ?? name;
}

function lastPathComponent(p: string): string {
  const cleaned = p.replace(/[\\/]+$/, "");
  const idx = Math.max(cleaned.lastIndexOf("\\"), cleaned.lastIndexOf("/"));
  return idx >= 0 ? cleaned.slice(idx + 1) : cleaned;
}

/**
 * What a tool does, in a word — the macOS app's frenchStep(), in English like
 * the rest of the island here.
 */
const TOOL_LABELS: Record<string, string> = {
  Bash: "Runs",
  Read: "Reads",
  Write: "Writes",
  Edit: "Edits",
  Glob: "Finds",
  Grep: "Searches",
  WebSearch: "Searches the web",
  WebFetch: "Fetches",
  TodoWrite: "Todos",
  Task: "Agent",
  LS: "Lists",
  MultiEdit: "Edits",
  NotebookEdit: "Notebook",
  PowerShell: "Runs",
};

function stepLabel(tool: string, input: Record<string, unknown>): string {
  const label = TOOL_LABELS[tool] ?? tool;
  const str = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : null);
  const cmd = str("command");
  if (cmd) return `${label} · ${cmd.slice(0, 40)}`;
  const path = str("path");
  if (path) return `${label} · ${lastPathComponent(path)}`;
  const file = str("file_path");
  if (file) return `${label} · ${lastPathComponent(file)}`;
  const query = str("query");
  if (query) return `${label} · ${query.slice(0, 40)}`;
  return label;
}

/**
 * What the Allow button actually authorises. Approving "Write" tells you nothing
 * — approving `Write · C:\…\.env` tells you everything, and the difference is
 * the whole point of approving from the island rather than blind.
 *
 * Ordered by how specific the field is, so an unfamiliar tool still shows
 * whatever identifying string it carries instead of falling back to its name.
 */
const APPROVAL_FIELDS = [
  "command", // Bash, PowerShell
  "file_path", // Write, Edit, MultiEdit, NotebookEdit
  "path", // Read, LS
  "url", // WebFetch
  "query", // WebSearch
  "pattern", // Glob, Grep
  "prompt", // Task
] as const;

function approvalTarget(tool: string, input: Record<string, unknown>): string {
  for (const field of APPROVAL_FIELDS) {
    const value = input[field];
    if (typeof value === "string" && value.trim()) {
      return `${tool} · ${value.trim()}`;
    }
  }
  return tool;
}

export function registerHookHandlers(island: Island) {
  void onEvent<HookPayload>("hook", (payload) => handleHook(island, payload));
}

/**
 * An event from a third-party agent (docs/AGENTS.md): it has a pill of its
 * own, "agent_<name>", created on its first event and gone when it is done.
 * None of what follows a Claude Code session — its journal, its questions —
 * applies to it: the pill wears the agent's state and its last steps.
 */
function handleAgent(island: Island, payload: HookPayload, agent: string) {
  const agentId = `agent_${agent}`;
  const name = payload.hook_event_name ?? "";
  const focused = State.focusId === agentId;
  const ensurePill = () => State.upsertExternalAgent(agentId, agent, agentColor(agent));
  const reveal = () => {
    if (State.mode === "hidden") island.reveal();
  };
  const alert = (view: IslandViewName) => (State.mode === "expanded" ? island.setView(view) : island.alert(view));

  switch (name) {
    case "SessionStart":
      ensurePill();
      reveal();
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      ensurePill();
      State.updateTask(agentId, "thinking");
      const asked = payload.prompt ?? payload.message;
      if (asked) State.appendStep(agentId, asked.slice(0, LINE_CHARS));
      reveal();
      break;
    }

    case "PreToolUse":
      ensurePill();
      State.updateTask(agentId, "working");
      State.appendStep(agentId, stepLabel(payload.tool_name ?? "Tool", payload.tool_input ?? {}));
      reveal();
      break;

    case "PostToolUse":
      State.updateTask(agentId, "working");
      break;

    case "PostToolUseFailure":
      State.updateTask(agentId, "working");
      State.appendStep(agentId, "⚠ failed");
      break;

    case "Notification": {
      const message = payload.message ?? "";
      const lower = message.toLowerCase();
      if (lower.includes("rate limit") || lower.includes("limite d")) {
        State.updateTask(agentId, "ratelimit");
        Sound.play("rate");
      } else if (message.endsWith("?")) {
        State.updateTask(agentId, "question");
        State.appendStep(agentId, message);
      }
      break;
    }

    case "Stop":
      State.updateTask(agentId, "finished");
      if (payload.message) State.appendStep(agentId, payload.message.slice(0, LINE_CHARS));
      Sound.play("finish");
      if (focused) alert("finished");
      else State.setPillBadge(agentId, "finished");
      window.setTimeout(() => State.removeTask(agentId), FINISHED_MS);
      break;

    case "StopFailure":
      State.updateTask(agentId, "error");
      Sound.play("error");
      if (focused) alert("error");
      else State.setPillBadge(agentId, "error");
      break;

    case "SessionEnd":
      State.removeTask(agentId);
      break;

    case "SubagentStart":
      State.appendStep(agentId, "+ subagent");
      break;

    case "SubagentStop":
      State.appendStep(agentId, "• subagent done");
      break;

    case "PermissionRequest":
      // External agents do not get an approval card — showing one would look like
      // a Claude Code request. Decline immediately so the agent re-asks in its
      // terminal. Approval support for other agents will come with Codex support.
      if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
      break;

    default:
      break;
  }
  State.notify();
}

/** Exported for the dev preview, which plays a session without Claude Code. */
export function handleHook(island: Island, payload: HookPayload) {
  // Route to the right pill. Valid coucou_agent → dynamic "agent_<name>" pill.
  // "claude" is reserved; absent or invalid → Claude Code, as before.
  const agent = validateAgent(payload.coucou_agent);
  if (agent && !State.paused) return handleAgent(island, payload, agent);

  // Paused, or a session nobody is sitting in front of: the island does not look.
  if (State.paused || isAutomated(payload)) {
    // Silence here used to cost Claude Code nearly two minutes: the relay waited
    // for a decision from an island that had already decided not to look. Say so,
    // and the terminal takes the question immediately.
    if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
    return;
  }

  const name = payload.hook_event_name ?? "";

  if (name === "SessionEnd") {
    const over = State.sessions.find((s) => s.id === (payload.session_id || ANONYMOUS));
    if (over) forget(island, over);
    State.notify();
    return;
  }

  const session = sessionOf(island, payload);
  if (takesFront(session, name)) State.bringForward(session.id);
  /** The session the island shows; the others go on behind their tabs. */
  const front = session.id === State.frontId;
  const focused = front && State.focusId === CLAUDE_ID;
  const cwd = payload.cwd ?? "";

  /** Alerts force the island open; work events only reveal the compact island. */
  const surface = (view: IslandViewName, isAlert: boolean) => {
    if (State.mode === "expanded") {
      if (isAlert) island.setView(view);
    } else if (isAlert) {
      island.alert(view);
    } else if (State.mode === "hidden") {
      island.reveal();
    }
  };

  /**
   * A turn's end, good or bad: its card when the session is in front, a mark
   * on its tab when it is behind, a badge on the pill when Claude's is not
   * the one in front.
   */
  const tell = (what: "finished" | "error") => {
    if (focused) return surface(what, true);
    if (!front) session.news = what;
    if (State.focusId !== CLAUDE_ID) State.setPillBadge(CLAUDE_ID, what);
  };

  switch (name) {
    case "SessionStart":
      surface("overview", false);
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      session.state = "thinking";
      // The field is `prompt`; reading `message` meant this step was always blank.
      const asked = payload.prompt ?? payload.message;
      // What Claude Code feeds itself as a prompt — a task's notification, a
      // reminder — comes as markup, and is nobody's words to show.
      if (asked && !asked.trimStart().startsWith("<")) {
        session.asked = asked;
        session.answer = null;
        log(session, newStep("Prompt", "prompt", asked));
        say(session, asked.slice(0, LINE_CHARS));
      }
      surface("overview", false);
      break;
    }

    case "PreToolUse": {
      session.state = "working";
      const tool = payload.tool_name ?? "Tool";
      startStep(session, tool, payload.tool_input ?? {}, cwd);
      say(session, stepLabel(tool, payload.tool_input ?? {}));
      surface("overview", false);
      break;
    }

    case "PostToolUse":
      if (answeredElsewhere(session, payload)) dropPending(island, session);
      endStep(session, payload, "done");
      recordChange(session, payload);
      session.state = "working";
      break;

    case "PostToolUseFailure":
      if (answeredElsewhere(session, payload)) dropPending(island, session);
      endStep(session, payload, "failed");
      session.state = "working";
      say(session, "⚠ failed");
      break;

    case "Notification": {
      const message = payload.message ?? "";
      const lower = message.toLowerCase();
      if (lower.includes("rate limit") || lower.includes("limite d")) {
        session.state = "ratelimit";
        Sound.play("rate");
      } else if (message.endsWith("?")) {
        session.state = "question";
        say(session, message);
      }
      if (message) log(session, newStep("Notification", "note", message));
      break;
    }

    case "Stop":
      if (payload.last_message) {
        session.answer = payload.last_message;
        session.answeredAt = Date.now();
      }
      closeSteps(session, payload.last_message ?? null);
      session.state = "finished";
      if (payload.message) say(session, payload.message.slice(0, LINE_CHARS));
      Sound.play("finish");
      tell("finished");
      window.setTimeout(() => {
        // Still where its turn left it: back to rest. Its tab keeps its mark.
        if (session.state === "finished") session.state = "idle";
        if (session.id === State.frontId) State.setPillBadge(CLAUDE_ID, null);
        State.present();
      }, FINISHED_MS);
      break;

    case "StopFailure":
      log(session, newStep("Error", "note", "The session stopped on an error.")).state = "failed";
      session.state = "error";
      Sound.play("error");
      tell("error");
      break;

    case "SubagentStart":
      say(session, "+ subagent");
      log(session, newStep("Subagent", "note", "A subagent started."));
      break;

    case "SubagentStop":
      say(session, "• subagent done");
      log(session, newStep("Subagent", "note", "A subagent finished."));
      break;

    case "PermissionRequest": {
      const requestId = payload.request_id ?? "";
      // One request per session. A second one must never quietly replace the
      // first — that would leave a human staring at request B while request A
      // waits for a decision nobody can give. Hand it straight back to the terminal.
      const held = session.approval ?? session.question;
      if (held && held.requestId !== requestId) {
        if (requestId) void Bridge.approvalDecline(requestId);
        break;
      }
      stopWaiting(session);
      const tool = payload.tool_name ?? "Tool";
      const input = payload.tool_input ?? {};
      // Claude's question tool asks for permission like any other: allowing it
      // with the answers is how a question gets answered from here.
      const questions = tool === QUESTION_TOOL ? questionsOf(input) : null;
      if (questions) session.question = { requestId, sessionId: session.id, questions };
      else {
        const file = input.file_path;
        const proposal =
          payload.proposal && typeof file === "string" ? { path: sessionPath(file, cwd), ...payload.proposal } : null;
        session.approval = { requestId, sessionId: session.id, tool, command: approvalTarget(tool, input), proposal };
      }
      // The journal says the tool had to ask, and later what it was told.
      const asking = goingStep(session, tool);
      if (asking) asking.permission = "asked";
      // The relay's short ack window closes in 800 ms; everything below this
      // line is synchronous, so the card really is up by the time it lands.
      if (requestId) void Bridge.approvalAck(requestId);
      session.state = questions ? "question" : "approval";
      Sound.play(questions ? "question" : "approval");
      if (!front) {
        // The session in front is waiting for an answer of its own: this one
        // waits its turn behind its tab, and gets the card next.
        session.news = "approval";
      } else if (focused) {
        State.isPinned = true;
        island.alert(questions ? "question" : "approval");
      } else {
        // Another agent holds the view, so the card would yank it away. The badge
        // is the signal instead — but it has to be on screen for that to mean
        // anything, hence the reveal. We just told the relay a human can act.
        State.isPinned = true;
        State.setPillBadge(CLAUDE_ID, "approval");
        island.reveal();
      }
      pendingTimeouts.set(session.id, window.setTimeout(() => {
        dropPending(island, session);
        State.present();
      }, PENDING_MS));
      break;
    }

    default:
      break;
  }
  State.present();
}

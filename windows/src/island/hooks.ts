// Agent hook events → session-scoped island state.
// Port of HookServer.processEvent / processPermissionRequest from the macOS app.
// Difference from macOS: no terminal filter in this handler. It accepts hook
// events regardless of terminal context; real Claude delivery and approval in
// VS Code and standalone terminals still require live verification.

import { Bridge, onEvent, type HermesPending } from "../core/bridge";
import { Sound } from "../core/sound";
import { allAnswered, liveLabels, parseQuestions, sameText } from "../core/questions";
import { State, taskId, type ApprovalInfo, type QuestionInfo, type SessionOrigin } from "../core/state";
import type { Island } from "./island";

const CLAUDE_ID = "integration_claude";

/** Clears the approval card if no decision was made before the hook gave up. */
let pendingTimeout: number | null = null;

interface HookPayload {
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
  /** Window the session started from (coucou-hook); absent when not found. */
  origin_hwnd?: number;
  origin_pid?: number;
  origin_console_pid?: number;
}

function originOf(payload: HookPayload): SessionOrigin | null {
  const { origin_hwnd: hwnd, origin_pid: pid, origin_console_pid: consolePid } = payload;
  if (!Number.isSafeInteger(hwnd) || !Number.isSafeInteger(pid) || !hwnd || !pid || pid < 0) return null;
  const tabPid = Number.isSafeInteger(consolePid) && (consolePid as number) > 0 ? (consolePid as number) : null;
  return { hwnd: hwnd as number, pid: pid as number, consolePid: tabPid };
}

const STOP_DELAY_MS = 5200;
const STALE_SESSION_MS = 30 * 60 * 1000;
const retireTimers = new Map<string, number>();
const generations = new Map<string, number>();
const endedSessions = new Map<string, number>();
const restartedSessions = new Set<string>();

window.setInterval(() => retireStaleSessions(Date.now()), 60_000);

function cancelRetirement(id: string): number {
  const timer = retireTimers.get(id);
  if (timer != null) window.clearTimeout(timer);
  retireTimers.delete(id);
  const generation = (generations.get(id) ?? 0) + 1;
  generations.set(id, generation);
  return generation;
}

function retireStaleSessions(now: number) {
  for (const task of [...State.tasks]) {
    if (!task.sessionId || task.lastEventAt == null || now - task.lastEventAt <= STALE_SESSION_MS) continue;
    if (State.pendingApproval?.taskId === task.id) continue;
    cancelRetirement(task.id);
    restartedSessions.delete(task.id);
    State.removeTask(task.id);
  }
  for (const [id, endedAt] of endedSessions) {
    if (now - endedAt > STALE_SESSION_MS) endedSessions.delete(id);
  }
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

/** frenchStep() — same labels as the macOS app. */
const TOOL_LABELS: Record<string, string> = {
  Bash: "Exécute",
  Read: "Lit",
  Write: "Écrit",
  Edit: "Modifie",
  Glob: "Cherche",
  Grep: "Recherche",
  WebSearch: "Recherche web",
  WebFetch: "Récupère",
  TodoWrite: "Tâches",
  Task: "Agent",
  LS: "Liste",
  MultiEdit: "Modifie",
  NotebookEdit: "Notebook",
  PowerShell: "Exécute",
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

function upsert(projectName: string, cwd: string, origin: SessionOrigin | null) {
  const t = State.tasks.find((x) => x.id === CLAUDE_ID);
  if (!t) return;
  t.name = projectName;
  if (cwd) t.sessionCwd = cwd;
  if (origin) {
    t.originHwnd = origin.hwnd;
    t.originPid = origin.pid;
    t.originConsolePid = origin.consolePid ?? null;
  }
}

function clearSession() {
  const t = State.tasks.find((x) => x.id === CLAUDE_ID);
  if (!t) return;
  t.steps = [];
  t.stepIndex = 0;
  t.name = "Claude Code";
  t.pillBadge = null;
  t.originHwnd = null;
  t.originPid = null;
  t.originConsolePid = null;
}

export function registerHookHandlers(island: Island) {
  void onEvent<HookPayload>("hook", (payload) => handleHook(island, payload));
}

export function clearPendingApprovalTimer() {
  if (pendingTimeout != null) window.clearTimeout(pendingTimeout);
  pendingTimeout = null;
}

/**
 * Submit on a Claude question card: sends the picks by question index and
 * returns the request it answered, or null when not every question is answered.
 * The relay maps the indexes back onto its own copy of the questions.
 */
export function submitQuestionAnswers(): ApprovalInfo | null {
  const req = State.pendingApproval;
  if (!req?.questions || !allAnswered(req)) return null;
  void Bridge.approvalAnswers(req.requestId, req.picks!.map((p) => [...p]));
  clearPendingApprovalTimer();
  State.pendingApproval = null;
  return req;
}

/** "Answer in app": release the card so Claude Code asks in its own interface. */
export function releaseQuestionToApp(): ApprovalInfo | null {
  const req = State.pendingApproval;
  if (!req) return null;
  void Bridge.approvalDecline(req.requestId);
  clearPendingApprovalTimer();
  State.pendingApproval = null;
  return req;
}

export const HERMES_ALREADY_ANSWERED = "Already answered in Hermes.";

/** How long to wait for Hermes to ask the next question after an answer. */
const HERMES_NEXT_MS = 6_000;
const HERMES_POLL_MS = 400;

const sleep = (ms: number) => new Promise<void>((resolve) => window.setTimeout(resolve, ms));

/**
 * The live Hermes entry for the question on the card: same session (or the
 * only open question), first unanswered question text matches.
 */
function liveHermesEntry(entries: HermesPending[], shown: QuestionInfo): HermesPending | null {
  const fits = entries.filter((e) => e.questions.length > 0 && sameText(shown.question, e.questions[0].question));
  return fits.length === 1 ? fits[0] : null;
}

/**
 * Sends the picks of a Hermes question card. Hermes keeps asking in Telegram
 * and its desktop app; the first answer wins. A gateway (Telegram) entry holds
 * one question, so after each answer the next one is looked up again.
 * Returns what happened, for the card and the tests.
 */
export async function submitHermesAnswers(taskId: string): Promise<"answered" | "expired" | "missing" | "busy" | "error"> {
  const task = State.tasks.find((t) => t.id === taskId);
  if (!task?.questions || !task.sessionId || task.agent !== "hermes" || !allAnswered(task)) return "missing";
  if (task.questionStatus === "sending") return "busy";
  const questions = task.questions;
  const picks = task.picks!.map((p) => [...p]);
  const session = task.sessionId;
  const stillOurs = () => {
    const now = State.tasks.find((t) => t.id === taskId);
    return now === task && now.questions === questions;
  };
  const finish = (status: string | null, outcome: "answered" | "expired" | "missing" | "error") => {
    if (!stillOurs()) return outcome;
    if (outcome === "answered") {
      task.questions = null;
      task.picks = undefined;
      task.step = undefined;
      task.questionStatus = null;
      if (task.state === "question") State.updateTask(taskId, "working");
    } else if (outcome === "expired") {
      // Telegram or Hermes Desktop was first: the card closes, and its picks are dropped.
      task.questionStatus = status;
      task.picks = questions.map(() => []);
    } else {
      task.questionStatus = status;
    }
    State.notify();
    return outcome;
  };
  task.questionStatus = "sending";
  State.notify();
  let index = 0;
  try {
    while (index < questions.length) {
      let entry: HermesPending | null = null;
      const deadline = Date.now() + (index === 0 ? 0 : HERMES_NEXT_MS);
      for (;;) {
        const report = await Bridge.hermesClarifyPending(session);
        if (!stillOurs()) return "missing";
        if (index === 0 && report.hermes === 0) {
          return finish("Hermes isn't reachable from Coucou — answer in Hermes. (Install Coucou's Hermes hooks again and restart Hermes.)", "missing");
        }
        entry = liveHermesEntry(report.entries, questions[index]);
        if (entry || Date.now() >= deadline) break;
        await sleep(HERMES_POLL_MS);
      }
      // None left after an answer: Hermes moved on (or the rest was answered there).
      if (!entry) return index === 0 ? finish(HERMES_ALREADY_ANSWERED, "expired") : finish(null, "answered");
      const answers: string[][] = [];
      for (const live of entry.questions) {
        const at = questions.findIndex((q, i) => i >= index && sameText(q.question, live.question));
        const labels = at >= 0 ? liveLabels(picks[at] ?? [], live.choices) : null;
        if (!labels?.length) return finish("This question changed in Hermes — answer it there.", "error");
        answers.push(labels);
      }
      const reply = await Bridge.hermesClarifyAnswer(entry.pid, entry.kind, entry.id, answers);
      if (!reply.ok) {
        return reply.reason === "expired"
          ? finish(HERMES_ALREADY_ANSWERED, "expired")
          : finish("Hermes refused this answer — answer it there.", "error");
      }
      index += entry.questions.length;
    }
    return finish(null, "answered");
  } catch (err) {
    void Bridge.log(`hermes clarify: ${String(err)}`);
    return finish("Couldn't reach Hermes — answer it there.", "error");
  }
}

const EXTERNAL_QUESTION_TOOLS: Record<string, string> = {
  "kimi-code": "AskUserQuestion",
  codex: "request_user_input",
  hermes: "clarify",
};

/** Agents whose PermissionRequest Coucou can answer (Allow/Deny goes back to them). */
const ANSWERABLE_AGENTS = new Set(["claude", "codex"]);

/** Views the user is typing or working in: an outcome must not replace them. */
const BUSY_VIEWS = new Set(["prompt", "task", "robot", "settings", "upload", "uploading", "choose", "mail"]);

function handleHook(island: Island, payload: HookPayload) {
  if (State.paused) {
    // Silence here used to cost Claude Code nearly two minutes: the relay waited
    // for a decision from an island that had already decided not to look. Say so,
    // and the terminal takes the question immediately.
    if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
    return;
  }

  const name = payload.hook_event_name ?? "";
  const cwd = payload.cwd ?? "";
  const raw = lastPathComponent(cwd);
  const projectName = aliasProjectName(raw || "Session");

  const agent = payload.coucou_agent ?? "claude";
  const sessionId = payload.session_id?.trim() ?? "";
  if (payload.coucou_agent !== undefined && !/^(?!claude$)[a-z0-9-]{1,24}$/.test(agent)) return;
  if (payload.coucou_agent !== undefined && !sessionId) return;
  const agentId = sessionId ? taskId(agent, sessionId) : CLAUDE_ID;
  const isExternalAgent = agent !== "claude";
  const origin = originOf(payload);
  const now = Date.now();
  retireStaleSessions(now);
  if (name === "SessionEnd") {
    if (sessionId && endedSessions.has(agentId)) return;
    // A reused ID cannot identify which process emitted a delayed end. Ignore
    // the first end after an explicit restart rather than erase newer work.
    if (sessionId && restartedSessions.delete(agentId)) return;
    cancelRetirement(agentId);
    if (State.pendingApproval?.taskId === agentId) {
      if (State.pendingApproval.requestId) void Bridge.approvalDecline(State.pendingApproval.requestId);
      clearPendingApprovalTimer();
      State.pendingApproval = null;
      State.isPinned = false;
      island.dropPin();
      if (State.view === "approval") island.setView(State.defaultView());
    }
    if (sessionId) {
      endedSessions.set(agentId, now);
      State.removeTask(agentId);
    } else {
      State.updateTask(CLAUDE_ID, "idle");
      clearSession();
    }
    State.notify();
    return;
  }
  let restarted = false;
  if (sessionId && endedSessions.has(agentId)) {
    if (name !== "SessionStart") return;
    endedSessions.delete(agentId);
    restartedSessions.add(agentId);
    restarted = true;
  }
  const awaitingDecision = () => State.pendingApproval?.taskId === agentId;
  const ensurePill = () => {
    cancelRetirement(agentId);
    // Any later event means the external question or approval was answered or abandoned.
    const asking = State.tasks.find((t) => t.id === agentId);
    if (asking?.questions) {
      asking.questions = null;
      asking.picks = undefined;
      asking.step = undefined;
      asking.questionStatus = null;
      if (State.view === "question" && State.focusId === agentId) island.setView(State.defaultView());
    }
    if (asking?.approvalNotice) {
      asking.approvalNotice = null;
      if (State.view === "notice" && State.focusId === agentId) island.setView(State.defaultView());
      if (asking.pillBadge === "approval" && State.pendingApproval?.taskId !== agentId) asking.pillBadge = null;
    }
    if (sessionId) {
      const t = State.upsertAgentSession(agent, sessionId, cwd ? projectName : "", cwd, origin);
      if (name !== "Stop" && name !== "StopFailure" && !awaitingDecision()) t.pillBadge = null;
    } else {
      upsert(projectName, cwd, origin);
      if (name !== "Stop" && name !== "StopFailure" && !awaitingDecision()) State.setPillBadge(agentId, null);
    }
  };

  /** Alerts force the island open; work events only reveal the compact island. */
  const surface = (view: Parameters<Island["alert"]>[0], isAlert: boolean) => {
    if (State.mode === "expanded") {
      // alert(), not setView(): the card must be pinned even when the island
      // was already open with its auto-close countdown running.
      if (isAlert && (State.view !== "approval" || !State.pendingApproval)) island.alert(view);
    } else if (isAlert) {
      if (State.pendingApproval) island.reveal();
      else island.alert(view);
    } else if (State.mode === "hidden") {
      island.reveal();
    }
  };

  /**
   * Something the user must see from another session holds the island: an
   * approval waiting for a click, another session's question or notice card,
   * or a view they are typing in. An outcome then becomes a pill badge that
   * stays until that pill is clicked.
   */
  const islandBusy = () => {
    if (State.pendingApproval && State.pendingApproval.taskId !== agentId) return true;
    if (State.mode !== "expanded") return false;
    if ((State.view === "question" || State.view === "notice") && State.focusId !== agentId) return true;
    return BUSY_VIEWS.has(State.view);
  };

  /**
   * A session finished or failed: open its outcome card the way a focused
   * session's would, or badge its pill when the island is busy. Sessions that
   * are not focused get the focus, so the card is about them.
   */
  const announce = (view: "finished" | "error") => {
    const badge = view;
    if (islandBusy()) {
      State.setPillBadge(agentId, badge);
      island.reveal();
      return;
    }
    const previous = State.focusTask;
    const shown = State.mode === "expanded" && (State.view === "finished" || State.view === "error") ? State.view : null;
    State.setFocus(agentId);
    // Another session's outcome card being replaced keeps its trace as a badge.
    if (previous && previous.id !== agentId && shown) previous.pillBadge = shown;
    surface(view, true);
  };

  switch (name) {
    case "SessionStart":
      ensurePill();
      if (restarted && !awaitingDecision()) {
        const task = State.tasks.find((t) => t.id === agentId);
        if (task) {
          task.state = "idle";
          task.steps = [];
          task.stepIndex = 0;
          task.pillBadge = null;
        }
      }
      surface("overview", false);
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      ensurePill();
      if (!awaitingDecision()) State.updateTask(agentId, "thinking");
      // The field is `prompt`; reading `message` meant this step was always blank.
      const asked = payload.prompt ?? payload.message;
      if (asked) State.appendStep(agentId, asked.slice(0, 60));
      surface("overview", false);
      break;
    }

    case "PreToolUse": {
      const tool = payload.tool_name ?? "Tool";
      const asked = isExternalAgent && EXTERNAL_QUESTION_TOOLS[agent] === tool
        ? parseQuestions(payload.tool_input)
        : null;
      ensurePill();
      if (asked) {
        // Kimi and Codex take the answer in their own window. Hermes can be
        // answered from the card too (coucou-clarify plugin); it still asks there.
        const task = State.tasks.find((t) => t.id === agentId);
        if (task) {
          task.questions = asked;
          task.picks = asked.map(() => []);
          task.step = 0;
          task.questionStatus = null;
        }
        if (!awaitingDecision()) State.updateTask(agentId, "question");
        State.appendStep(agentId, asked[0].question.slice(0, 60));
        Sound.play("question");
        if (State.pendingApproval) {
          State.setPillBadge(agentId, "approval");
          island.reveal();
        } else {
          State.setFocus(agentId);
          island.alert("question");
        }
        break;
      }
      if (!awaitingDecision()) State.updateTask(agentId, "working");
      State.appendStep(agentId, stepLabel(tool, payload.tool_input ?? {}));
      surface("overview", false);
      break;
    }

    case "PostToolUse":
      ensurePill();
      if (!awaitingDecision()) State.updateTask(agentId, "working");
      break;

    case "PostToolUseFailure":
      ensurePill();
      if (!awaitingDecision()) State.updateTask(agentId, "working");
      State.appendStep(agentId, "⚠ failed");
      break;

    case "Notification": {
      const message = payload.message ?? "";
      const lower = message.toLowerCase();
      if (lower.includes("rate limit") || lower.includes("limite d")) {
        ensurePill();
        if (!awaitingDecision()) State.updateTask(agentId, "ratelimit");
        Sound.play("rate");
      } else if (message.endsWith("?")) {
        ensurePill();
        if (!awaitingDecision()) State.updateTask(agentId, "question");
        State.appendStep(agentId, message.slice(0, 60));
      }
      break;
    }

    case "Stop": {
      if (awaitingDecision()) {
        if (State.pendingApproval?.requestId) void Bridge.approvalDecline(State.pendingApproval.requestId);
        clearPendingApprovalTimer();
        State.pendingApproval = null;
        State.isPinned = false;
        island.dropPin();
        if (State.view === "approval") island.setView(State.defaultView());
      }
      ensurePill();
      const generation = generations.get(agentId);
      const stoppedTask = State.tasks.find((t) => t.id === agentId);
      State.updateTask(agentId, "finished");
      if (payload.message) State.appendStep(agentId, payload.message.slice(0, 60));
      Sound.play("finish");
      announce("finished");
      // Only the bot state relaxes; a "finished" badge stays until its pill is clicked.
      const timer = window.setTimeout(() => {
        if (generations.get(agentId) !== generation || State.tasks.find((t) => t.id === agentId) !== stoppedTask) return;
        retireTimers.delete(agentId);
        State.updateTask(agentId, "idle");
      }, STOP_DELAY_MS);
      retireTimers.set(agentId, timer);
      break;
    }

    case "StopFailure":
      if (awaitingDecision()) {
        if (State.pendingApproval?.requestId) void Bridge.approvalDecline(State.pendingApproval.requestId);
        clearPendingApprovalTimer();
        State.pendingApproval = null;
        State.isPinned = false;
        island.dropPin();
        if (State.view === "approval") island.setView(State.defaultView());
      }
      ensurePill();
      State.updateTask(agentId, "error");
      Sound.play("error");
      announce("error");
      break;

    case "SubagentStart":
      ensurePill();
      State.appendStep(agentId, "+ subagent");
      break;

    case "SubagentStop":
      ensurePill();
      State.appendStep(agentId, "• subagent done");
      break;

    case "ApprovalNotice": {
      // Kimi and Hermes: shown so it is not missed, answered in their own window.
      // Nothing is ever sent back.
      if (!isExternalAgent) break;
      ensurePill();
      const tool = payload.tool_name ?? "Tool";
      const task = State.tasks.find((t) => t.id === agentId);
      if (task) task.approvalNotice = approvalTarget(tool, payload.tool_input ?? {});
      if (!awaitingDecision()) State.updateTask(agentId, "approval");
      Sound.play("approval");
      if (State.pendingApproval || islandBusy()) {
        State.setPillBadge(agentId, "approval");
        island.reveal();
      } else {
        State.setFocus(agentId);
        island.alert("notice");
      }
      break;
    }

    case "PermissionRequest": {
      // Claude Code and Codex permission requests can be answered by Coucou.
      // Other agents never send one here (Kimi/Hermes come as ApprovalNotice).
      if (!ANSWERABLE_AGENTS.has(agent)) {
        if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
        break;
      }

      const requestId = payload.request_id ?? "";
      // One card, one request. A second one must never quietly replace the first
      // — that would leave a human staring at request B while request A waits for
      // a decision nobody can give. Hand it straight back to the terminal.
      if (State.pendingApproval &&
        (State.pendingApproval.requestId !== requestId || State.pendingApproval.taskId !== agentId)) {
        if (requestId) void Bridge.approvalDecline(requestId);
        break;
      }
      ensurePill();
      clearPendingApprovalTimer();
      const tool = payload.tool_name ?? "Tool";
      const input = payload.tool_input ?? {};
      // Only Claude's AskUserQuestion is answerable as a multiple-choice card.
      const questions = !isExternalAgent && tool === "AskUserQuestion" ? parseQuestions(input) : null;
      // A repeat of the card already up keeps the picks made so far.
      if (!State.pendingApproval) {
        State.pendingApproval = {
          requestId,
          sessionId,
          taskId: agentId,
          tool,
          command: questions ? questions[0].question : approvalTarget(tool, input),
          ...(questions ? { questions, picks: questions.map(() => []) } : {}),
        };
      }
      State.updateTask(agentId, questions ? "question" : "approval");
      State.isPinned = true;
      Sound.play(questions ? "question" : "approval");
      State.setFocus(agentId);
      island.alert("approval");
      if (requestId) void Bridge.approvalAck(requestId);
      pendingTimeout = window.setTimeout(() => {
        pendingTimeout = null;
        if (State.pendingApproval?.requestId !== requestId) return;
        State.pendingApproval = null;
        State.isPinned = false;
        island.dropPin();
        State.updateTask(agentId, "working");
        State.setPillBadge(agentId, null);
        if (State.view === "approval") island.setView(State.defaultView());
        State.notify();
      }, 110_000);
      break;
    }

    default:
      break;
  }
  State.notify();
}

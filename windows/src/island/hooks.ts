// Hook events from Claude Code and every other agent → island state.
// Port of HookServer.processEvent / processPermissionRequest from the macOS app.
// Difference from macOS: no terminal filter. On Windows the hook fires from any
// terminal (Windows Terminal, VS Code, PowerShell…) and all of them are handled.
// The relay has already mapped every agent's events and fields onto Claude
// Code's (hook/src/normalize.rs), so one handler serves them all.

import { Bridge, onEvent } from "../core/bridge";
import { buildFileDiff, fileName, lastTextStep, makeDiffStep, toOneLine } from "../core/diff";
import { Sound } from "../core/sound";
import { State, type AgentTask, type AskedQuestion } from "../core/state";
import { effortLevel } from "../core/session";
import { isSessionPill, pillDefinition, SESSION_PILL_PREFIX } from "../core/pills";
import { APPROVAL_AGENTS, agentColor, agentName, validateAgent } from "./agents";
import type { Island } from "./island";
import { parseClaudePlan, restorePlanUsage } from "../core/plan";
import { setClaudePlanUsage, storedClaudePlanUsage } from "../views/usage";
import { N_, t } from "../i18n/i18n";

const CLAUDE_ID = "integration_claude";
const CURSOR_ID = "agent_cursor";

/** Clears the approval card if no decision was made before the hook gave up. */
let pendingTimeout: number | null = null;

/** Takes the approval or question card down and gives the island back. */
function dropPendingCard(island: Island): void {
  if (!State.pendingApproval) return;
  State.endApproval();
  island.dropPin();
  if (State.view === "approval" || State.view === "question") {
    island.setView(State.defaultView());
  }
  State.notify();
}

/** The return to idle that Stop arms, per pill, so the next turn can cancel it. */
const stopTimers = new Map<string, number>();

function cancelStopTimer(id: string): boolean {
  const timer = stopTimers.get(id);
  if (timer == null) return false;
  window.clearTimeout(timer);
  stopTimers.delete(id);
  return true;
}

/** A session silent this long, and not busy, gives its pill up: it was closed without a SessionEnd. */
const STALE_SESSION_MS = 20 * 60_000;
/** States in which a session is doing something, or waiting on you. */
const ACTIVE_STATES = new Set(["thinking", "working", "approval", "question"]);

function isStale(t: AgentTask, now: number): boolean {
  return !ACTIVE_STATES.has(t.state) && t.lastEventAt != null && now - t.lastEventAt > STALE_SESSION_MS;
}

/**
 * The pill of a Claude Code session. One session per pill: the first one takes
 * Claude Code's own pill (VS Code's or Cursor's); another running at the same
 * time in another terminal gets a pill of its own, named after its project,
 * instead of overwriting the first one's steps, card and terminal.
 */
function claudePillFor(workspaceId: string, sessionId: string, now: number): string {
  if (!sessionId) return workspaceId;
  const own = State.tasks.find(
    (t) => t.sessionId === sessionId && (t.id === workspaceId || isSessionPill(t.id)),
  );
  if (own) return own.id;
  const main = State.tasks.find((t) => t.id === workspaceId);
  if (!main || !main.sessionId || isStale(main, now)) return workspaceId;
  return SESSION_PILL_PREFIX + sessionId.replace(/[^A-Za-z0-9-]/g, "").slice(0, 12);
}

/** Session pills whose session went quiet long ago (closed without SessionEnd) go. */
function dropStaleSessionPills(now: number): void {
  for (const t of State.tasks.filter((x) => isSessionPill(x.id) && isStale(x, now))) {
    cancelStopTimer(t.id);
    State.clearSessionDiffs(t.id);
    State.removeTask(t.id);
  }
}

/** "proj", or "proj 2" when another pill already shows a session of "proj". */
function sessionPillName(projectName: string, id: string): string {
  const taken = new Set(State.tasks.filter((t) => t.id !== id).map((t) => t.name));
  if (!taken.has(projectName)) return projectName;
  for (let n = 2; ; n++) if (!taken.has(`${projectName} ${n}`)) return `${projectName} ${n}`;
}

/** Events after which a pending permission request of the same session is moot. */
const TURN_OVER = new Set(["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt"]);

interface HookPayload {
  hook_event_name?: string;
  request_id?: string;
  session_id?: string;
  cwd?: string;
  message?: string;
  /** UserPromptSubmit carries `prompt`; `message` belongs to Notification/Stop. */
  prompt?: string;
  /** Stop: the turn's final answer (Markdown) — Claude Code's, Hermes's, Codex's. */
  last_assistant_message?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  /** Set by the relay when an edit was too big to forward whole (> 256 KB). */
  coucou_diff_truncated?: boolean;
  /** Optional agent tag: lowercase, digits and hyphens, ≤ 24 chars. */
  coucou_agent?: string;
  /** Hermes: where the session runs (telegram, discord…; "cli" in a terminal). */
  platform?: string;
  /** "cursor" when Claude Code runs in Cursor's terminal (set by the relay). */
  term_editor?: string;
  /** StatusLine (the plan usage relay): Claude Code's 5-hour and weekly limits. */
  rate_limits?: unknown;
  /** Claude Code's permission mode, on most events ("default", "plan"…). */
  permission_mode?: string;
  /** `{ level }` on Claude Code's events and its status line. */
  effort?: unknown;
  /** SessionStart: the model id. StatusLine: `{ id, display_name }`. */
  model?: unknown;
  /** PostModelSwitch: the model the session switched to. */
  to_model?: unknown;
  /** Set on every event fired inside a subagent, and on SubagentStart/Stop. */
  agent_id?: string;
  /** The subagent's kind ("Explore", "general-purpose"…). */
  agent_type?: string;
  /** MessageDisplay: the assistant message the text belongs to, and the text. */
  message_id?: string;
  turn_id?: string;
  delta?: string;
}

/** Per pill, the assistant message whose first words are already a step. */
const narrated = new Map<string, string>();

/** A subagent's kind, short enough for a step. */
function subagentName(payload: HookPayload): string {
  const type = (payload.agent_type ?? "").trim();
  return type ? type.slice(0, 24) : t("subagent");
}

/** Claude's own words, as a step: quoted, one line, short. */
function narrationStep(text: string): string {
  const line = toOneLine(text);
  return `“${line.length > 100 ? `${line.slice(0, 99)}…` : line}”`;
}

/** The model a payload names, as an id when there is one. */
function payloadModel(payload: HookPayload): string | null {
  const pick = (v: unknown): string | null => {
    if (typeof v === "string") return v.trim() || null;
    if (v && typeof v === "object") {
      const o = v as { id?: unknown; display_name?: unknown };
      return pick(o.id) ?? pick(o.display_name);
    }
    return null;
  };
  return pick(payload.to_model) ?? pick(payload.model);
}

/**
 * Keeps what the session runs with — mode, effort, model — on its pill, from
 * any event that says. A field an event leaves out keeps its last value.
 */
function recordSessionMeta(task: AgentTask | undefined, payload: HookPayload): boolean {
  if (!task) return false;
  let changed = false;
  const set = (key: "permissionMode" | "effort" | "model", value: string | null) => {
    if (value && task[key] !== value) {
      task[key] = value;
      changed = true;
    }
  };
  const mode = payload.permission_mode;
  set("permissionMode", typeof mode === "string" && /^[A-Za-z]{1,24}$/.test(mode) ? mode : null);
  set("effort", effortLevel(payload.effort));
  set("model", payloadModel(payload));
  return changed;
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
 * localizedStep() — same labels as the macOS app, in English and shown in the
 * interface language (src/i18n) when the step is recorded.
 */
const TOOL_LABELS: Record<string, string> = {
  Bash: N_("Runs"),
  Read: N_("Reads"),
  Write: N_("Writes"),
  Edit: N_("Edits"),
  Glob: N_("Searches"),
  Grep: N_("Searches"),
  WebSearch: N_("Searches the web"),
  WebFetch: N_("Fetches"),
  TodoWrite: N_("Tasks"),
  Task: N_("Agent"),
  LS: N_("Lists"),
  MultiEdit: N_("Edits"),
  NotebookEdit: N_("Notebook"),
  PowerShell: N_("Runs"),
  // Antigravity's tools (#298).
  run_command: N_("Runs"),
  view_file: N_("Reads"),
  write_to_file: N_("Writes"),
  replace_file_content: N_("Edits"),
  read_url_content: N_("Fetches"),
  search_web: N_("Searches the web"),
};

function stepLabel(tool: string, input: Record<string, unknown>): string {
  const label = TOOL_LABELS[tool] ? t(TOOL_LABELS[tool]) : tool;
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

/**
 * The questions of an AskUserQuestion call, if the island can show all of them
 * as options to pick from. Anything it cannot is left to the terminal.
 */
function askedQuestions(tool: string, input: Record<string, unknown>): AskedQuestion[] | null {
  if (tool !== "AskUserQuestion" || !Array.isArray(input.questions)) return null;
  const out: AskedQuestion[] = [];
  for (const raw of input.questions as Record<string, unknown>[]) {
    const question = typeof raw?.question === "string" ? raw.question : "";
    const options = (Array.isArray(raw?.options) ? (raw.options as Record<string, unknown>[]) : [])
      .filter((o) => typeof o?.label === "string" && o.label)
      .map((o) => ({
        label: o.label as string,
        description: typeof o.description === "string" ? o.description : "",
      }));
    // A question cut short by the relay would be answered under the wrong text.
    if (!question || question.endsWith("…") || options.length < 2) return null;
    out.push({ question, options, multiSelect: raw.multiSelect === true });
  }
  return out.length > 0 ? out : null;
}

/** The Claude Code session's pill, named after its project for the session. */
function upsert(id: string, projectName: string, cwd: string, sessionId: string) {
  adoptSession(State.upsertWorkspacePill(id, projectName, cwd), sessionId);
}

/** The pill now shows `sessionId`; what another session ran with is forgotten. */
function adoptSession(t: AgentTask | null | undefined, sessionId: string) {
  if (!t || !sessionId) return;
  if (t.sessionId && t.sessionId !== sessionId) {
    t.permissionMode = null;
    t.effort = null;
    t.model = null;
  }
  t.sessionId = sessionId;
}

/** The session is over: the pill goes back as it was, or away if it was only there for it. */
function clearSession(id: string) {
  const t = State.tasks.find((x) => x.id === id);
  if (!t) return;
  if (!State.isKept(id)) {
    State.removeTask(id);
    return;
  }
  t.state = "idle";
  t.steps = [];
  t.stepIndex = 0;
  delete t.stepSeq;
  t.name = pillDefinition(id)?.name ?? t.name;
  t.pillBadge = null;
  t.sessionId = null;
  t.finalLine = null;
  t.finalText = null;
  t.subagents = [];
  t.permissionMode = null;
  t.effort = null;
  t.model = null;
}

/** The final message stays on the card until the next turn starts. */
function clearFinalLine(id: string) {
  const t = State.tasks.find((x) => x.id === id);
  if (t) {
    t.finalLine = null;
    t.finalText = null;
  }
}

/**
 * PostToolUse of Edit / MultiEdit / Write → a diff stored for the pill and a
 * ticker step with its +N −M counts. Nothing is kept for a pill that does not
 * exist, so a stray event cannot grow memory. An edit the relay had to cut
 * would give wrong counts: the PreToolUse step ("Edits · file") stands alone.
 */
function recordDiff(agentId: string, payload: HookPayload) {
  if (payload.coucou_diff_truncated) return;
  if (!State.tasks.some((t) => t.id === agentId)) return;
  const diff = buildFileDiff(payload.tool_name ?? "", payload.tool_input ?? {});
  if (!diff) return;
  const id = State.appendSessionDiff(agentId, diff);
  State.appendStep(agentId, makeDiffStep(fileName(diff.path), diff.added, diff.removed, id));
}

export function registerHookHandlers(island: Island) {
  // The last plan numbers seen survive a restart, as on the Mac.
  State.planUsage ??= restorePlanUsage(storedClaudePlanUsage());
  void onEvent<HookPayload>("hook", (payload) => handleHook(island, payload));
}

function handleHook(island: Island, payload: HookPayload) {
  // Account-wide numbers from the status line relay, not part of any session:
  // keep the latest, nothing else (no reveal, no sound), paused or not.
  if (payload.hook_event_name === "StatusLine") {
    const usage = parseClaudePlan(payload.rate_limits);
    if (usage) setClaudePlanUsage(usage);
    // The model and effort it carries belong to the pill showing that session.
    const session = payload.session_id ? State.tasks.find((t) => t.sessionId === payload.session_id) : undefined;
    if (recordSessionMeta(session, payload)) State.notify();
    return;
  }

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

  // Route to the right pill. Valid coucou_agent → dynamic "agent_<name>" pill.
  // "claude" is reserved; absent or invalid → Claude Code's own pill: Cursor's
  // when it runs in Cursor's terminal (Mac #120), VS Code's otherwise.
  const validAgent = validateAgent(payload.coucou_agent);
  const workspaceId = payload.term_editor === "cursor" ? CURSOR_ID : CLAUDE_ID;
  const sessionId = payload.session_id ?? "";
  const now = Date.now();
  dropStaleSessionPills(now);
  const agentId = validAgent ? `agent_${validAgent}` : claudePillFor(workspaceId, sessionId, now);
  const isExternalAgent = validAgent !== null;
  /** A Claude Code session on a pill of its own, beside the one on Claude Code's pill. */
  const isExtraSession = isSessionPill(agentId);

  /** Alerts force the island open; work events only reveal the compact island. */
  const surface = (view: Parameters<Island["alert"]>[0], isAlert: boolean) => {
    if (State.mode === "expanded") {
      if (isAlert) island.setView(view);
    } else if (isAlert) {
      island.alert(view);
    } else if (State.mode === "hidden") {
      island.reveal();
    }
  };

  /** Ensure the agent pill exists (no-op for Claude Code). */
  const ensurePill = () => {
    if (isExternalAgent) {
      State.upsertExternalAgent(agentId, agentName(validAgent!), agentColor(validAgent!));
      const t = State.tasks.find((x) => x.id === agentId);
      if (t && cwd) t.sessionCwd = cwd;
      adoptSession(t, sessionId);
    } else if (isExtraSession) {
      const color = pillDefinition(workspaceId)?.color ?? "#d97757";
      State.upsertExternalAgent(agentId, sessionPillName(projectName, agentId), color);
      const t = State.tasks.find((x) => x.id === agentId);
      if (t && cwd) t.sessionCwd = cwd;
      adoptSession(t, sessionId);
    } else {
      upsert(agentId, projectName, cwd, sessionId);
    }
  };

  /**
   * Called where a handler is about to replace `finished` with a newer state:
   * the timer Stop armed would otherwise put the pill back to idle over it. The
   * badge that timer was going to clear goes now.
   */
  const supersedeStop = () => {
    if (cancelStopTimer(agentId)) State.setPillBadge(agentId, null);
  };

  // The turn that asked for a permission is over — answered in the terminal,
  // interrupted, or a new prompt — so the card would be lying. It goes, and the
  // relay is released without a decision. Same rule as the Mac.
  const pending = State.pendingApproval;
  if (
    pending &&
    TURN_OVER.has(name) &&
    pending.pillId === agentId &&
    pending.sessionId === (payload.session_id ?? "")
  ) {
    if (pendingTimeout != null) window.clearTimeout(pendingTimeout);
    pendingTimeout = null;
    if (pending.requestId) void Bridge.approvalDecline(pending.requestId);
    dropPendingCard(island);
  }

  // Read after the card above is dropped: its pill may have handed the front
  // back to the pill you were on.
  const focused = State.focusId === agentId;

  switch (name) {
    case "SessionStart":
      ensurePill();
      clearFinalLine(agentId);
      // Hermes through its gateway says where the session comes from.
      if (validAgent === "hermes" && payload.platform && payload.platform !== "cli") {
        State.appendStep(agentId, payload.platform.charAt(0).toUpperCase() + payload.platform.slice(1));
      }
      surface("overview", false);
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      ensurePill();
      supersedeStop();
      clearFinalLine(agentId);
      State.updateTask(agentId, "thinking");
      // The field is `prompt`; reading `message` meant this step was always blank.
      const asked = payload.prompt ?? payload.message;
      if (asked) State.appendStep(agentId, asked.slice(0, 60));
      surface("overview", false);
      break;
    }

    case "PreToolUse": {
      ensurePill();
      supersedeStop();
      clearFinalLine(agentId);
      State.updateTask(agentId, "working");
      const tool = payload.tool_name ?? "Tool";
      const label = stepLabel(tool, payload.tool_input ?? {});
      // A tool call inside a subagent says whose it is.
      State.appendStep(agentId, payload.agent_id ? `↳ ${subagentName(payload)} · ${label}` : label);
      surface("overview", false);
      break;
    }

    case "MessageDisplay": {
      // What Claude says between tool calls ("Let me check the config…") as it
      // appears in the terminal. It comes in batches of lines: the first batch
      // of each message becomes a step, the rest would only flood the ticker.
      const text = (payload.delta ?? "").trim();
      const key = payload.message_id ?? payload.turn_id ?? "";
      if (!text || !State.tasks.some((x) => x.id === agentId)) break;
      if (key && narrated.get(agentId) === key) break;
      narrated.set(agentId, key);
      State.appendStep(agentId, payload.agent_id ? `↳ ${subagentName(payload)} · ${narrationStep(text)}` : narrationStep(text));
      break;
    }

    case "PostToolUse":
      supersedeStop();
      // The question was answered in the terminal: the card would be lying.
      if (
        payload.tool_name === "AskUserQuestion" &&
        State.pendingApproval?.questions &&
        State.pendingApproval.sessionId === (payload.session_id ?? "")
      ) {
        if (pendingTimeout != null) window.clearTimeout(pendingTimeout);
        pendingTimeout = null;
        dropPendingCard(island);
      }
      State.updateTask(agentId, "working");
      recordDiff(agentId, payload);
      break;

    case "PostToolUseFailure":
      supersedeStop();
      State.updateTask(agentId, "working");
      State.appendStep(agentId, t("⚠ failed"));
      break;

    case "Notification": {
      const message = payload.message ?? "";
      const lower = message.toLowerCase();
      if (lower.includes("rate limit") || lower.includes("limite d")) {
        supersedeStop();
        State.updateTask(agentId, "ratelimit");
        Sound.play("rate");
      } else if (message.endsWith("?")) {
        supersedeStop();
        State.updateTask(agentId, "question");
        State.appendStep(agentId, message);
      }
      break;
    }

    case "Stop": {
      State.updateTask(agentId, "finished");
      // Claude Code puts the turn's answer in the Stop payload itself, so there is
      // no transcript to read (the relay does not even forward its path). Other
      // agents report their last words the same way (Hermes, Codex) or as
      // `message`.
      const fullText = (payload.last_assistant_message ?? payload.message ?? "").trim();
      const finalText = toOneLine(fullText);
      const stopped = State.tasks.find((x) => x.id === agentId);
      // The turn is over: no subagent of it is still running.
      if (stopped) stopped.subagents = [];
      narrated.delete(agentId);
      if (finalText) {
        // Its first words may already be a step, from MessageDisplay.
        const last = stopped ? lastTextStep(stopped.steps) : undefined;
        const said = last?.startsWith("“") ? last.slice(1).replace(/[”…]+$/, "") : null;
        if (!said || !finalText.startsWith(said)) State.appendStep(agentId, finalText);
        const t = stopped;
        if (t) {
          t.finalLine = finalText;
          t.finalText = fullText;
        }
      }
      Sound.play("finish");
      // A card waiting for an answer is never covered by another alert.
      if (focused && !State.pendingApproval) surface("finished", true);
      else State.setPillBadge(agentId, "finished");
      cancelStopTimer(agentId);
      stopTimers.set(
        agentId,
        window.setTimeout(() => {
          stopTimers.delete(agentId);
          if (isExternalAgent) {
            State.removeTask(agentId);
          } else {
            State.updateTask(agentId, "idle");
            State.setPillBadge(agentId, null);
          }
        }, 5200),
      );
      break;
    }

    case "Interrupt":
      // Codex: the user stopped the turn. Back to idle, nothing to celebrate.
      supersedeStop();
      State.updateTask(agentId, "idle");
      State.setPillBadge(agentId, null);
      break;

    case "StopFailure":
      supersedeStop();
      State.updateTask(agentId, "error");
      Sound.play("error");
      if (focused && !State.pendingApproval) surface("error", true);
      else State.setPillBadge(agentId, "error");
      break;

    case "SessionEnd":
      // Nothing left for the timer to do, and it must not outlive the session: a
      // pill recreated within 5.2 s would be removed by it.
      cancelStopTimer(agentId);
      State.clearSessionDiffs(agentId);
      if (isExternalAgent || isExtraSession) {
        State.removeTask(agentId);
      } else {
        State.updateTask(agentId, "idle");
        clearSession(agentId);
      }
      break;

    case "SubagentStart": {
      const task = State.tasks.find((x) => x.id === agentId);
      if (task && payload.agent_id && !task.subagents?.some((s) => s.id === payload.agent_id)) {
        task.subagents = [...(task.subagents ?? []), { id: payload.agent_id, type: subagentName(payload) }];
      }
      State.appendStep(agentId, payload.agent_type ? `${t("+ subagent")} · ${subagentName(payload)}` : t("+ subagent"));
      break;
    }

    case "SubagentStop": {
      const task = State.tasks.find((x) => x.id === agentId);
      if (task?.subagents && payload.agent_id) {
        task.subagents = task.subagents.filter((s) => s.id !== payload.agent_id);
      }
      State.appendStep(agentId, payload.agent_type ? `${t("• subagent done")} · ${subagentName(payload)}` : t("• subagent done"));
      break;
    }

    case "PermissionRequest": {
      // Only Claude Code and the agents the relay can answer for (Codex, Copilot
      // CLI, Muse Code — same as the Mac) get a card. Anyone else's request is
      // declined at once, so the agent asks in its own terminal.
      if (isExternalAgent && !APPROVAL_AGENTS.has(validAgent!)) {
        if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
        break;
      }

      const requestId = payload.request_id ?? "";
      // One card, one request. A second one must never quietly replace the first
      // — that would leave a human staring at request B while request A waits for
      // a decision nobody can give. Hand it straight back to the terminal.
      if (State.pendingApproval && State.pendingApproval.requestId !== requestId) {
        if (requestId) void Bridge.approvalDecline(requestId);
        break;
      }
      ensurePill();
      supersedeStop();
      if (pendingTimeout != null) window.clearTimeout(pendingTimeout);
      const tool = payload.tool_name ?? "Tool";
      const input = payload.tool_input ?? {};
      // Claude Code asking a question is not a permission to grant: the island
      // shows the options and sends back the one that was picked. Only Claude
      // Code asks questions this way.
      const questions = isExternalAgent ? null : askedQuestions(tool, input);
      const view = questions ? "question" : "approval";
      // The card always comes up, even over another pill or an island that is
      // already open: its pill comes to the front, and the one you were on
      // comes back once you answer (Mac #117, #120).
      State.beginApproval({
        requestId,
        sessionId,
        pillId: agentId,
        tool,
        command: approvalTarget(tool, input),
        ...(questions ? { questions } : {}),
        // Only Claude Code takes a mode switch with its answer.
        ...(!isExternalAgent && payload.permission_mode ? { permissionMode: payload.permission_mode } : {}),
      });
      // The relay's short ack window closes in 800 ms; everything below this
      // line is synchronous, so the card really is up by the time it lands.
      if (requestId) void Bridge.approvalAck(requestId);
      State.updateTask(agentId, view);
      Sound.play(view);
      // Any agent's card (Claude Code, Codex, Copilot CLI, Muse Code) comes up
      // the same way: beginApproval brought its pill to the front.
      island.alert(view);
      // Coucou answers within 108 s or not at all; after that the terminal has
      // taken over and the card would be lying.
      pendingTimeout = window.setTimeout(() => {
        pendingTimeout = null;
        dropPendingCard(island);
      }, 110_000);
      break;
    }

    default:
      break;
  }
  // The pill now shows this session: keep what it runs with. A session that has
  // ended has nothing left to show.
  if (name !== "SessionEnd") {
    const t = State.tasks.find((x) => x.id === agentId);
    if (t && (!sessionId || !t.sessionId || t.sessionId === sessionId)) {
      recordSessionMeta(t, payload);
      t.lastEventAt = now;
    }
  }
  State.notify();
}

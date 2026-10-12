// Hook events from Claude Code and every other agent → island state.
// Port of HookServer.processEvent / processPermissionRequest from the macOS app.
// Difference from macOS: no terminal filter. On Windows the hook fires from any
// terminal (Windows Terminal, VS Code, PowerShell…) and all of them are handled.
// The relay has already mapped every agent's events and fields onto Claude
// Code's (hook/src/normalize.rs), so one handler serves them all.

import { Bridge, onEvent } from "../core/bridge";
import { buildFileDiff, fileName, makeDiffStep, toOneLine } from "../core/diff";
import { Sound } from "../core/sound";
import { State, type AskedQuestion } from "../core/state";
import { pillDefinition } from "../core/pills";
import { APPROVAL_AGENTS, agentColor, agentName, validateAgent } from "./agents";
import { enqueueApproval, releaseApproval, resetApprovals, resolveApprovals } from "./approvals";
import { approvalInputKey } from "./queue";
import { SessionRegistry } from "./sessions";
import type { Island } from "./island";
import { parseClaudePlan, restorePlanUsage } from "../core/plan";
import { setClaudePlanUsage, storedClaudePlanUsage } from "../views/usage";
import { N_, t } from "../i18n/i18n";

const CLAUDE_ID = "integration_claude";
const CURSOR_ID = "agent_cursor";

/** Takes the approval or question card down and gives the island back. */
export function dropPendingCard(island: Island): void {
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

/** Events that only continue a turn: one stamped before the session's Stop is late, not new. */
const TURN_EVENTS = new Set([
  "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification", "SubagentStart", "SubagentStop",
]);

/**
 * The live sessions behind each pill (Mac #245). A pill is picked from the
 * client, never the session, so several sessions can share one — and one of
 * them ending must not erase what the others are still doing.
 */
const sessions = new SessionRegistry();

/** Test seam: sessions, the approval queue and the armed timers start cold. */
export function resetHookState(): void {
  sessions.clear();
  resetApprovals();
  for (const timer of stopTimers.values()) window.clearTimeout(timer);
  stopTimers.clear();
}

function cancelStopTimer(id: string): boolean {
  const timer = stopTimers.get(id);
  if (timer == null) return false;
  window.clearTimeout(timer);
  stopTimers.delete(id);
  return true;
}

/**
 * A prompt as the session's step line. Claude Code also submits text the
 * user never typed (a background task's `<task-notification>`, system
 * reminders, slash-command echoes): those show as their summary or command,
 * or not at all, never as raw tags.
 */
export function promptStep(raw: string): string | null {
  const tag = (name: string) => raw.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))?.[1]?.trim();
  if (raw.includes("<task-notification>")) return tag("summary") ?? null;
  const command = tag("command-name");
  if (command) return command;
  const text = raw
    .replace(/<(system-reminder|local-command-\w+)>[\s\S]*?<\/\1>/g, "")
    .replace(/<[^>]+>/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return text ? text.slice(0, 60) : null;
}

/** How Claude Code's permission modes read on the Always button. */
const MODE_WORDS: Record<string, string> = {
  acceptEdits: "edits",
  bypassPermissions: "everything",
};

/** Where Claude Code saves an Always rule, in words. */
const DESTINATIONS: Record<string, string> = {
  session: "for this session only",
  localSettings: "in .claude/settings.local.json",
  projectSettings: "in .claude/settings.json",
  userSettings: "in ~/.claude/settings.json",
};

/**
 * Claude Code's `permission_suggestions` (the terminal's "Yes, and don't ask
 * again…") → the Always button's words, or null when it offered nothing. The
 * rules stay with the relay, which hands back exactly these; this only says
 * what they are: "Always allow Bash(npm test:*)".
 */
export function alwaysOffer(raw: unknown): { label: string; detail: string } | null {
  if (!Array.isArray(raw) || raw.length === 0) return null;
  const what: string[] = [];
  const where = new Set<string>();
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const s = item as Record<string, unknown>;
    if (typeof s.destination === "string") where.add(s.destination);
    if ((s.type === "addRules" || s.type === "replaceRules") && Array.isArray(s.rules) && s.behavior !== "deny") {
      for (const r of s.rules as Record<string, unknown>[]) {
        if (typeof r?.toolName !== "string" || !r.toolName) continue;
        const content = typeof r.ruleContent === "string" ? r.ruleContent.trim() : "";
        what.push(content ? `${r.toolName}(${content})` : r.toolName);
      }
    } else if (s.type === "setMode" && typeof s.mode === "string" && MODE_WORDS[s.mode]) {
      what.push(MODE_WORDS[s.mode]);
    } else if (s.type === "addDirectories" && Array.isArray(s.directories)) {
      for (const d of s.directories) {
        if (typeof d === "string" && d.trim()) what.push(`files in ${lastPathComponent(d.trim()) || d.trim()}`);
      }
    }
  }
  let rules = what.join(", ");
  if (rules.length > 48) rules = `${rules.slice(0, 47)}…`;
  const sessionOnly = where.size > 0 && [...where].every((d) => DESTINATIONS[d] === DESTINATIONS.session);
  const label = sessionOnly
    ? (rules ? `Allow ${rules} this session` : "Allow for this session")
    : rules ? `Always allow ${rules}` : "Always allow";
  const saved = [...where].map((d) => DESTINATIONS[d] ?? d).join(", ");
  const detail = `Allow, and let Claude Code remember ${what.length ? what.join(", ") : "this permission"}${saved ? ` ${saved}` : ""}.`;
  return { label, detail };
}

interface HookPayload {
  hook_event_name?: string;
  /** When the relay process saw the event (ms since the epoch): orders events that arrive out of order. */
  coucou_ts?: number;
  request_id?: string;
  session_id?: string;
  cwd?: string;
  /** The session's own name (Claude Code's /rename) and the home folder, from the hook. */
  session_name?: string;
  home?: string;
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
  /** Third-party opt-in: a blocking Allow / Deny card instead of an instant re-ask. */
  coucou_approval?: boolean;
  /** Hermes: where the session runs (telegram, discord…; "cli" in a terminal). */
  platform?: string;
  /** "cursor" when Claude Code runs in Cursor's terminal (set by the relay). */
  term_editor?: string;
  /** StatusLine (the plan usage relay): Claude Code's 5-hour and weekly limits. */
  rate_limits?: unknown;
  /** PermissionRequest: what "Yes, and don't ask again" would save (Claude Code). */
  permission_suggestions?: unknown;
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
    // A question cut short by the relay would be answered under the wrong text,
    // and two with the same text would share one answer.
    if (!question || question.endsWith("…") || options.length < 2) return null;
    if (out.some((q) => q.question === question)) return null;
    out.push({ question, options, multiSelect: raw.multiSelect === true });
  }
  // Claude Code asks one to four at a time; anything else is not ours to guess.
  return out.length > 0 && out.length <= 4 ? out : null;
}

/** The Claude Code session's pill, named after its project for the session. */
function upsert(id: string, projectName: string, cwd: string, sessionId: string) {
  // The pill's name and folder belong to its oldest live session (Mac #245):
  // a second session behind the same pill must not rename the card under it.
  const existing = State.tasks.some((x) => x.id === id);
  if (existing && !sessions.ownsDisplay(id, sessionId)) return;
  const t = State.upsertWorkspacePill(id, projectName, cwd);
  if (t && sessionId) t.sessionId = sessionId;
}

/** Rewrites the pill's name, cwd and session from the session that owns it —
 * used when the owner ends and a sibling session inherits the card. */
function applyDisplayOwner(agentId: string, isExternalAgent: boolean): void {
  const owner = sessions.displayOwner(agentId);
  const t = State.tasks.find((x) => x.id === agentId);
  if (!owner || !t) return;
  if (owner.session) t.sessionId = owner.session;
  if (!isExternalAgent && owner.projectName) t.name = owner.projectName;
  if (!isExternalAgent && owner.cwd) t.sessionCwd = owner.cwd;
  State.notify();
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
}

/** The final message stays on the card until the next turn starts. */
function clearFinalLine(id: string) {
  const t = State.tasks.find((x) => x.id === id);
  if (t) t.finalLine = null;
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
  // The relay stopped waiting for a request (src-tauri/src/pipe.rs): its card goes.
  void onEvent<{ requestId: string }>("approval-released", (p) => releaseApproval(island, p.requestId));
}

function handleHook(island: Island, payload: HookPayload) {
  // Account-wide numbers from the status line relay, not part of any session:
  // keep the latest, nothing else (no reveal, no sound), paused or not.
  if (payload.hook_event_name === "StatusLine") {
    const usage = parseClaudePlan(payload.rate_limits);
    if (usage) setClaudePlanUsage(usage);
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
  const raw = cwd && cwd === payload.home ? "~" : lastPathComponent(cwd);
  const projectName = payload.session_name || aliasProjectName(raw || "Session");

  // Route to the right pill. Valid coucou_agent → dynamic "agent_<name>" pill.
  // "claude" is reserved; absent or invalid → Claude Code's own pill: Cursor's
  // when it runs in Cursor's terminal (Mac #120), VS Code's otherwise.
  const validAgent = validateAgent(payload.coucou_agent);
  const workspaceId = payload.term_editor === "cursor" ? CURSOR_ID : CLAUDE_ID;
  const agentId = validAgent ? `agent_${validAgent}` : workspaceId;
  const isExternalAgent = validAgent !== null;
  const sessionId = payload.session_id ?? "";
  const relayTs = typeof payload.coucou_ts === "number" ? payload.coucou_ts : undefined;
  if (relayTs !== undefined && TURN_EVENTS.has(name) && sessions.sentBeforeTurnEnded(agentId, sessionId, relayTs)) {
    return; // belongs to a turn that is already over
  }

  // Several sessions can share one pill — it is chosen from the client, not
  // from the session. The registry tells a terminal event whether it may touch
  // the pill, and which session owns the displayed project.
  const display = {
    session: sessionId,
    projectName: isExternalAgent ? (validAgent ?? projectName) : projectName,
    cwd: isExternalAgent ? "" : cwd,
  };

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

  /**
   * Records the session behind the event and ensures its pill exists (no-op
   * for Claude Code's own). `working` says the event means a turn is running:
   * a PreToolUse does, a SessionStart does not. The pill's name, cwd and
   * session only move when this session owns the display.
   */
  const ensurePill = (working: boolean) => {
    sessions.note(agentId, display, working);
    if (isExternalAgent) {
      State.upsertExternalAgent(agentId, agentName(validAgent!), agentColor(validAgent!));
      const t = State.tasks.find((x) => x.id === agentId);
      if (t && sessions.ownsDisplay(agentId, sessionId)) {
        if (cwd) t.sessionCwd = cwd;
        if (sessionId) t.sessionId = sessionId;
      }
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

  // Requests this event makes moot — the turn that asked is over, or the very
  // tool call it asked about finished — release them to their terminals and
  // drop their cards. Matching is per request (session + pill, plus tool and
  // input for PostToolUse), so a parallel session never drops a card that is
  // not its own.
  resolveApprovals(
    island,
    name,
    sessionId,
    agentId,
    payload.tool_name ?? "",
    approvalInputKey(payload.tool_input ?? {}),
  );

  // Read after the card above is dropped: its pill may have handed the front
  // back to the pill you were on.
  const focused = State.focusId === agentId;

  switch (name) {
    case "SessionStart":
      ensurePill(false);
      clearFinalLine(agentId);
      // Hermes through its gateway says where the session comes from.
      if (validAgent === "hermes" && payload.platform && payload.platform !== "cli") {
        State.appendStep(agentId, payload.platform.charAt(0).toUpperCase() + payload.platform.slice(1));
      }
      surface("overview", false);
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      ensurePill(true);
      supersedeStop();
      clearFinalLine(agentId);
      State.updateTask(agentId, "thinking");
      // The field is `prompt`; reading `message` meant this step was always blank.
      const asked = promptStep(payload.prompt ?? payload.message ?? "");
      if (asked) State.appendStep(agentId, asked);
      // A new turn: the finished card would show the prompt as if it were the answer.
      if (State.mode === "expanded" && State.view === "finished" && State.focusId === agentId) island.setView("overview");
      surface("overview", false);
      break;
    }

    case "PreToolUse": {
      ensurePill(true);
      supersedeStop();
      clearFinalLine(agentId);
      State.updateTask(agentId, "working");
      const tool = payload.tool_name ?? "Tool";
      State.appendStep(agentId, stepLabel(tool, payload.tool_input ?? {}));
      surface("overview", false);
      break;
    }

    case "PostToolUse":
    case "PostToolUseFailure":
      supersedeStop();
      // The session is mid-turn — and if a card asked about this very tool
      // call, resolveApprovals above already took it down.
      sessions.note(agentId, display, true);
      State.updateTask(agentId, "working");
      if (name === "PostToolUse") {
        recordDiff(agentId, payload);
        break;
      }
      State.appendStep(agentId, t("⚠ failed"));
      break;

    case "Notification": {
      sessions.note(agentId, display, false);
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
      const scope = sessions.endTurn(agentId, sessionId, Date.now(), relayTs);
      // Claude Code puts the turn's answer in the Stop payload itself, so there is
      // no transcript to read (the relay does not even forward its path). Other
      // agents report their last words the same way (Hermes, Codex) or as
      // `message`.
      const finalText = toOneLine(payload.last_assistant_message ?? payload.message ?? "");
      // The step log is shared, so the conclusion is worth showing either way.
      if (finalText) State.appendStep(agentId, finalText);
      // Another session is still mid-turn behind this pill: a finished state,
      // the sound and the forced idle below would all land on its work. It gets
      // its own Stop when its turn really ends.
      if (scope === "sessionOnly") break;
      State.updateTask(agentId, "finished");
      const stopped = State.tasks.find((x) => x.id === agentId);
      if (finalText && stopped) stopped.finalLine = finalText;
      Sound.play("finish");
      // A card waiting for an answer is never covered by another alert.
      if (focused && !State.pendingApproval) surface("finished", true);
      else State.setPillBadge(agentId, "finished");
      cancelStopTimer(agentId);
      stopTimers.set(
        agentId,
        window.setTimeout(() => {
          stopTimers.delete(agentId);
          // A sibling session may have started working during the delay.
          if (sessions.workingCount(agentId) > 0) return;
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
      // Codex: the user stopped the turn. Back to idle, nothing to celebrate —
      // unless a sibling session behind this pill is still working.
      if (sessions.endTurn(agentId, sessionId, Date.now(), relayTs) !== "pill") break;
      supersedeStop();
      State.updateTask(agentId, "idle");
      State.setPillBadge(agentId, null);
      break;

    case "StopFailure":
      if (sessions.endTurn(agentId, sessionId, Date.now(), relayTs) !== "pill") break;
      supersedeStop();
      State.updateTask(agentId, "error");
      Sound.play("error");
      if (focused && !State.pendingApproval) surface("error", true);
      else State.setPillBadge(agentId, "error");
      break;

    case "SessionEnd":
      // Only the last session behind the pill may take the card down.
      if (sessions.endSession(agentId, sessionId) !== "pill") {
        applyDisplayOwner(agentId, isExternalAgent);
        break;
      }
      // Nothing left for the timer to do, and it must not outlive the session: a
      // pill recreated within 5.2 s would be removed by it.
      cancelStopTimer(agentId);
      State.clearSessionDiffs(agentId);
      if (isExternalAgent) {
        State.removeTask(agentId);
      } else {
        State.updateTask(agentId, "idle");
        clearSession(agentId);
      }
      break;

    case "SubagentStart":
      State.appendStep(agentId, t("+ subagent"));
      break;

    case "SubagentStop":
      State.appendStep(agentId, t("• subagent done"));
      break;

    case "PermissionRequest": {
      // Only Claude Code and the agents the relay can answer for (Codex, Copilot
      // CLI, Muse Code, OpenCode — same as the Mac) get a card, plus any agent
      // that sent "coucou_approval": true — it opted into the wait and reads
      // the permissionDecision the relay then prints. Anyone else's request is
      // declined at once, so the agent asks in its own terminal.
      if (isExternalAgent && !APPROVAL_AGENTS.has(validAgent!) && payload.coucou_approval !== true) {
        if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
        break;
      }

      const requestId = payload.request_id ?? "";
      ensurePill(true);
      supersedeStop();
      const tool = payload.tool_name ?? "Tool";
      const input = payload.tool_input ?? {};
      // Claude Code asking a question is not a permission to grant: the island
      // shows the options and sends back the one that was picked. Claude
      // Desktop asks through the same hook payload; other agents don't.
      const questions =
        isExternalAgent && validAgent !== "claude-desktop" ? null : askedQuestions(tool, input);
      // Claude Code may offer to remember the permission: then the card also
      // has "Always allow". No other agent's relay can save a rule.
      const always = isExternalAgent || questions ? null : alwaysOffer(payload.permission_suggestions);
      // Requests line up FIFO instead of replacing each other — a second one
      // used to be declined outright while a card was up. A full queue hands
      // the newest back to its terminal: never an implicit allow.
      const outcome = enqueueApproval(island, {
        requestId,
        sessionId,
        pillId: agentId,
        tool,
        command: approvalTarget(tool, input),
        ...(typeof input.description === "string" && input.description.trim()
          ? { description: input.description.trim() }
          : {}),
        ...(questions ? { questions } : {}),
        inputKey: approvalInputKey(input),
        ...(always ? { always } : {}),
      });
      if (outcome === "full" && requestId) void Bridge.approvalDecline(requestId);
      break;
    }

    default:
      break;
  }
  State.notify();
}

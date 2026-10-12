// Android companion: pushes what the island shows into the user's relay box
// (phone.rs) and applies what the phone sends back. A remote Allow or Deny is
// delivered through the same bridge commands as the island's own buttons, so
// the pending-request bookkeeping stays identical.

import { Bridge, onEvent } from "./bridge";
import { State } from "./state";
import type { Island } from "../island/island";

interface RemoteItem {
  type: "decision" | "chat" | "chat_sel";
  at: number;
  requestId?: string;
  decision?: string;
  /** Question text → the label picked, or the labels for a multi-select question. */
  answers?: Record<string, string | string[]>;
  text?: string;
  sessionId?: string;
  /** Which CLI the session belongs to — "devin" | "claude" | "codex" | "opencode" (default devin). */
  agent?: string;
}

interface ChatLine {
  role: string;
  text: string;
  name?: string;
}

let wired = false;
let pushTimer: ReturnType<typeof setTimeout> | undefined;
/** The request id the phone was last woken for — alerts fire once per card. */
let lastAlerted: string | null = null;
/** CLI sessions offered to the phone; refreshed every minute at most. */
let sessionsCache: { id: string; title: string; dir: string; at: number; agent: string }[] = [];
let sessionsFetchedAt = 0;
/** The CLI session the phone selected, and its transcript tail. */
let selectedSession: { agent: string; id: string } | null = null;
let transcriptCache: { id: string; lines: ChatLine[] } | null = null;
let transcriptFetchedAt = 0;
/** The last state the relay accepted, as sent: an unchanged one is not sent again. */
let lastSent = "";

/** CLI sessions a phone message is running in right now, as "agent:id". */
const running = new Set<string>();

/** Test seam: forgets what was pushed, offered and selected. */
export function resetPhoneState(): void {
  if (pushTimer !== undefined) clearTimeout(pushTimer);
  pushTimer = undefined;
  lastAlerted = null;
  lastSent = "";
  running.clear();
  sessionsCache = [];
  sessionsFetchedAt = 0;
  selectedSession = null;
  transcriptCache = null;
  transcriptFetchedAt = 0;
}

export function wirePhone(island: Island) {
  if (wired) return;
  wired = true;
  State.subscribe(schedulePush);
  void onEvent<RemoteItem[]>("phone-remote", (items) => applyRemote(island, items));
}

function schedulePush() {
  if (pushTimer !== undefined) return;
  pushTimer = setTimeout(() => {
    pushTimer = undefined;
    void push();
  }, 400);
}

/** The island's state, trimmed to the shape the relay keeps. */
function snapshot() {
  const sessions = State.tasks
    .filter((t) => t.source === "agent" || t.source === "claudeCode")
    .map((t) => ({
      pillId: t.id,
      agent: t.name,
      color: t.color,
      state: t.state,
      statusText: t.finalLine ?? t.steps[t.steps.length - 1] ?? "",
      stepIndex: t.stepSeq ?? t.stepIndex,
      stepCount: t.steps.length,
    }));

  let awaiting;
  const req = State.pendingApproval;
  if (req) {
    const pill = State.tasks.find((t) => t.id === req.pillId);
    const questions = (req.questions ?? []).map((q) => ({
      q: q.question,
      options: q.options.map((o) => o.label),
      multi: q.multiSelect,
    }));
    awaiting = {
      requestId: req.requestId,
      pillId: req.pillId,
      agent: pill?.name ?? req.pillId,
      kind: req.questions ? "question" : "approval",
      title: req.tool,
      detail: req.command,
      options: questions.flatMap((q) => q.options),
      questions,
    };
  }

  const chatTail = State.chatHistory.slice(-10).map((m) => ({ role: m.role, text: m.content }));
  return { sessions, awaiting, chatTail };
}

type SessionList = () => Promise<{ id: string; title: string; dir: string; lastActivityAt: number }[] | null>;

/** Each CLI's session store, by the agent id the phone sends. */
const SESSION_SOURCES: Record<string, {
  list: SessionList;
  transcript: (id: string) => Promise<ChatLine[] | null>;
  resume: (id: string, text: string) => Promise<string>;
}> = {
  devin: { list: Bridge.devinSessions, transcript: Bridge.devinTranscript, resume: Bridge.devinResume },
  claude: { list: Bridge.claudeSessions, transcript: Bridge.claudeTranscript, resume: Bridge.claudeResume },
  codex: { list: Bridge.codexSessions, transcript: Bridge.codexTranscript, resume: Bridge.codexResume },
  opencode: { list: Bridge.opencodeSessions, transcript: Bridge.opencodeTranscript, resume: Bridge.opencodeResume },
};

const source = (agent: string) => SESSION_SOURCES[agent] ?? SESSION_SOURCES.devin;
const agentTranscript = (agent: string, id: string) => source(agent).transcript(id);
const agentResume = (agent: string, id: string, text: string) => source(agent).resume(id, text);

/** CLI sessions + the selected transcript — fetched lazily, cached briefly. */
async function remoteSessions() {
  if (Date.now() - sessionsFetchedAt > 60_000) {
    const fetch = async (
      list: () => Promise<{ id: string; title: string; dir: string; lastActivityAt: number }[] | null>,
      agent: string,
    ) =>
      ((await list().catch(() => null)) ?? []).map((s) => ({
        id: s.id,
        title: s.title,
        dir: s.dir,
        at: s.lastActivityAt,
        agent,
      }));
    const lists = await Promise.all(
      Object.entries(SESSION_SOURCES).map(([agent, s]) => fetch(s.list, agent)),
    );
    sessionsCache = lists.flat();
    sessionsFetchedAt = Date.now();
  }
  if (selectedSession && Date.now() - transcriptFetchedAt > 5_000) {
    try {
      const lines = (await agentTranscript(selectedSession.agent, selectedSession.id)) ?? [];
      transcriptCache = { id: selectedSession.id, lines };
      transcriptFetchedAt = Date.now();
    } catch {
      // Transcript stays as it was.
    }
  }
  if (!selectedSession) transcriptCache = null;
  return cachedSessions();
}

/** What is already known of the CLI sessions, without asking for more. */
function cachedSessions() {
  return {
    chatSessions: sessionsCache,
    chatSel: selectedSession?.id ?? "",
    chatTranscript: selectedSession ? transcriptCache : null,
  };
}

async function push() {
  const base = snapshot();
  const alertId = base.awaiting?.requestId ?? null;
  const alert = alertId !== null && alertId !== lastAlerted;
  // A card wakes the phone now; the session lists are read for the next push.
  const state = { ...base, ...(alert ? cachedSessions() : await remoteSessions()) };
  const body = JSON.stringify(state);
  if (!alert && body === lastSent) return;
  // Not delivered: lastSent and lastAlerted stay as they were, so the next change retries.
  if ((await Bridge.phoneState(state, alert)) !== true) return;
  lastSent = body;
  if (alert) {
    lastAlerted = alertId;
    schedulePush();
  }
}

/** Phone → island. Answers only ever apply to the card actually waiting. */
function applyRemote(island: Island, items: RemoteItem[]) {
  for (const item of items) {
    if (item.type === "decision") {
      const req = State.pendingApproval;
      if (!item.requestId || req?.requestId !== item.requestId) {
        void Bridge.log(`phone decision for stale request ${item.requestId ?? "?"} — ignored`);
        continue;
      }
      if (item.decision === "allow" || item.decision === "deny") {
        void Bridge.approvalDecision(req.requestId, item.decision);
        island.closeApproval();
      } else if (item.decision === "answer" && item.answers) {
        void Bridge.approvalAnswer(req.requestId, item.answers);
        island.closeApproval();
      }
    } else if (item.type === "chat_sel") {
      // The phone picked a CLI session to read and continue ("" = island chat).
      selectedSession = item.sessionId
        ? { agent: item.agent ?? "devin", id: item.sessionId }
        : null;
      transcriptCache = null;
      transcriptFetchedAt = 0;
      void push();
    } else if (item.type === "chat" && item.text) {
      void remoteChat(item.text, item.sessionId, item.agent ?? selectedSession?.agent ?? "devin");
    }
  }
}

/**
 * A chat line typed on the phone. With a session id it continues that CLI's
 * session (`devin -p … -r …`, `claude -p … --resume …`) — the run's own hooks
 * light up the island like a normal CLI session — and the phone sees the
 * transcript grow. Without one it goes through the island's own provider.
 */
async function remoteChat(text: string, sessionId?: string, agent = "devin") {
  if (sessionId) {
    // The id came over the network: only a session the phone was offered.
    const offered = () => sessionsCache.some((s) => s.id === sessionId && s.agent === agent);
    if (!offered()) {
      sessionsFetchedAt = 0;
      await remoteSessions();
    }
    if (!offered()) {
      void Bridge.log(`phone chat for a ${agent} session it was not offered — ignored`);
      return;
    }
    const key = `${agent}:${sessionId}`;
    if (running.has(key)) {
      appendTranscriptNote(sessionId, "(still answering the previous message)");
      void push();
      return;
    }
    running.add(key);
    try {
      await agentResume(agent, sessionId, text);
      const lines = (await agentTranscript(agent, sessionId)) ?? [];
      transcriptCache = { id: sessionId, lines };
    } catch (e) {
      appendTranscriptNote(sessionId, `(${e instanceof Error ? e.message : "the CLI could not be reached"})`);
    } finally {
      running.delete(key);
    }
    transcriptFetchedAt = Date.now();
    void push();
    return;
  }
  State.chatHistory.push({ id: Date.now(), role: "user", content: text });
  State.notify();
  try {
    const reply = await Bridge.chatSend(text, null);
    if (reply) {
      State.chatHistory.push({ id: Date.now() + 1, role: "assistant", content: reply.text });
    }
  } catch {
    State.chatHistory.push({
      id: Date.now() + 1,
      role: "assistant",
      content: "(the chat could not be reached)",
    });
  }
  State.notify();
}

/** One assistant line of ours at the end of the session's transcript on the phone. */
function appendTranscriptNote(sessionId: string, text: string) {
  transcriptCache = {
    id: sessionId,
    lines: [...(transcriptCache?.id === sessionId ? transcriptCache.lines : []), { role: "assistant", text }],
  };
}

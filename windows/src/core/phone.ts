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
  answers?: Record<string, string>;
  text?: string;
  sessionId?: string;
  /** Which CLI the session belongs to — "devin" | "claude" (default devin). */
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

/** Session list, transcript and resume — routed by which CLI owns the id. */
function agentTranscript(agent: string, id: string) {
  switch (agent) {
    case "claude": return Bridge.claudeTranscript(id);
    case "codex": return Bridge.codexTranscript(id);
    case "opencode": return Bridge.opencodeTranscript(id);
    default: return Bridge.devinTranscript(id);
  }
}

function agentResume(agent: string, id: string, text: string) {
  switch (agent) {
    case "claude": return Bridge.claudeResume(id, text);
    case "codex": return Bridge.codexResume(id, text);
    case "opencode": return Bridge.opencodeResume(id, text);
    default: return Bridge.devinResume(id, text);
  }
}

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
    const [devin, claude, codex, opencode] = await Promise.all([
      fetch(Bridge.devinSessions, "devin"),
      fetch(Bridge.claudeSessions, "claude"),
      fetch(Bridge.codexSessions, "codex"),
      fetch(Bridge.opencodeSessions, "opencode"),
    ]);
    sessionsCache = [...devin, ...claude, ...codex, ...opencode];
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
  return {
    chatSessions: sessionsCache,
    chatSel: selectedSession?.id ?? "",
    chatTranscript: transcriptCache,
  };
}

async function push() {
  const state = { ...snapshot(), ...(await remoteSessions()) };
  // A fresh card is the only thing that may wake the phone.
  const alertId = state.awaiting?.requestId ?? null;
  const alert = alertId !== null && alertId !== lastAlerted;
  if (alertId !== lastAlerted) lastAlerted = alertId;
  await Bridge.phoneState(state, alert);
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
    try {
      await agentResume(agent, sessionId, text);
      const lines = (await agentTranscript(agent, sessionId)) ?? [];
      transcriptCache = { id: sessionId, lines };
    } catch (e) {
      transcriptCache = {
        id: sessionId,
        lines: [
          ...(transcriptCache?.id === sessionId ? transcriptCache.lines : []),
          { role: "assistant", text: `(${e instanceof Error ? e.message : "the CLI could not be reached"})` },
        ],
      };
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

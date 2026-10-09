// Android companion: pushes what the island shows into the user's relay box
// (phone.rs) and applies what the phone sends back. A remote Allow or Deny is
// delivered through the same bridge commands as the island's own buttons, so
// the pending-request bookkeeping stays identical.

import { Bridge, onEvent } from "./bridge";
import { State } from "./state";
import type { Island } from "../island/island";

interface RemoteItem {
  type: "decision" | "chat";
  at: number;
  requestId?: string;
  decision?: string;
  answers?: Record<string, string>;
  text?: string;
}

let wired = false;
let pushTimer: ReturnType<typeof setTimeout> | undefined;
/** The request id the phone was last woken for — alerts fire once per card. */
let lastAlerted: string | null = null;

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

async function push() {
  const state = snapshot();
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
    } else if (item.type === "chat" && item.text) {
      void remoteChat(item.text);
    }
  }
}

/** A chat line typed on the phone goes through the island's own provider. */
async function remoteChat(text: string) {
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

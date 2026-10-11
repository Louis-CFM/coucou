// The approval wait line — the Windows/Linux counterpart of HookServer's
// approvalQueue + refreshApprovalCard (Mac #157). queue.ts holds the FIFO
// order; this file owns the per-request timers, the bridge answers and the
// card on screen. `State.pendingApproval` is always a projection of the queue
// head: the request the card answers is the request it showed.

import { Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import { agentName } from "./agents";
import type { Island } from "./island";
import { ApprovalQueue, type QueuedApproval } from "./queue";

const queue = new ApprovalQueue();

/** Each request's own deadline, armed at arrival like the Mac's WorkItem. */
const timers = new Map<string, number>();

let nextId = 0;

/** Coucou answers within 110 s or not at all; after that the agent re-asks. */
const WAIT_MS = 110_000;

function syncBadge(pillId: string): void {
  State.setPillBadge(pillId, queue.hasEntries(pillId) ? "approval" : null);
}

function removeEntry(entry: QueuedApproval): void {
  const timer = timers.get(entry.id);
  if (timer != null) {
    window.clearTimeout(timer);
    timers.delete(entry.id);
  }
  queue.remove(entry.id);
}

function armTimer(island: Island, entry: QueuedApproval): void {
  timers.set(
    entry.id,
    window.setTimeout(() => {
      timers.delete(entry.id);
      if (!queue.remove(entry.id)) return;
      // Nobody answered in time — hand the request back to its own terminal.
      if (entry.requestId) void Bridge.approvalDecline(entry.requestId);
      syncBadge(entry.pillId);
      if (State.pendingApproval?.id === entry.id) refreshApprovals(island, entry.pillId);
    }, WAIT_MS),
  );
}

/** The pill label under the card when requests of different sources wait. */
function sourceLabel(pillId: string): string {
  return pillId.startsWith("agent_") ? agentName(pillId.slice(6)) : "Claude Code";
}

/**
 * Makes `entry` (the queue head) the card on screen. `alert` is only for the
 * request that started the line — later promotions keep the island where it
 * is: open shows the card, folded waits for the next open.
 */
function showApprovalCard(island: Island, entry: QueuedApproval, alert: boolean): void {
  const view = entry.questions ? "question" : "approval";
  State.beginApproval({
    id: entry.id,
    requestId: entry.requestId,
    sessionId: entry.sessionId,
    pillId: entry.pillId,
    tool: entry.tool,
    command: entry.command,
    ...(entry.description ? { description: entry.description } : {}),
    ...(entry.questions ? { questions: entry.questions } : {}),
    inputKey: entry.inputKey,
    position: queue.position(entry.id) || 1,
    total: queue.count,
    ...(queue.hasMixedSources ? { sourceLabel: sourceLabel(entry.pillId) } : {}),
  });
  State.updateTask(entry.pillId, view);
  if (alert) {
    Sound.play(view);
    island.alert(view);
  } else if (State.mode === "expanded") {
    island.setView(view);
  }
}

/**
 * Brings the card and pill states in line with the queue after any removal.
 * Non-empty: the next live request becomes the card. Empty: release the island
 * as before.
 */
function refreshApprovals(island: Island, releasedPill: string): void {
  // A pill with no request left goes back to work; one still waiting keeps its
  // badge — the card may belong to a sibling request on it.
  if (!queue.hasEntries(releasedPill)) {
    State.updateTask(releasedPill, "working");
    State.setPillBadge(releasedPill, null);
  }
  const head = queue.head;
  if (head) {
    showApprovalCard(island, head, false);
    State.notify();
    return;
  }
  // pendingApproval still points at the released card: endApproval lifts the
  // pin and hands the front back to the pill you were on.
  State.endApproval();
  island.dropPin();
  if (State.view === "approval" || State.view === "question") {
    island.setView(State.defaultView());
  }
  State.notify();
}

/**
 * A request arrives. The first one takes the card; the rest line up behind it
 * with a badge on their pill instead of being handed straight back (the old
 * behavior — a second request used to be declined outright). A full queue says
 * "full": the caller declines, and the agent re-asks in its terminal — never
 * an implicit allow.
 */
export function enqueueApproval(island: Island, entry: Omit<QueuedApproval, "id">): "shown" | "queued" | "full" {
  // The same request delivered twice refreshes instead of doubling the line.
  const dupe = queue.byRequestId(entry.requestId);
  if (dupe) {
    const timer = timers.get(dupe.id);
    if (timer != null) window.clearTimeout(timer);
    armTimer(island, dupe);
    if (queue.head === dupe) {
      showApprovalCard(island, dupe, true);
      return "shown";
    }
    syncBadge(dupe.pillId);
    return "queued";
  }
  const queued = { ...entry, id: `q${++nextId}` };
  if (queue.enqueue(queued) === "rejectedFull") return "full";
  // The relay's short ack window closes in 800 ms whether the request is the
  // card or waits in line — answer it now, exactly once. A second Ack would
  // land in the decision wait and look like a timeout, releasing the hook.
  if (queued.requestId) void Bridge.approvalAck(queued.requestId);
  armTimer(island, queued);
  if (queue.head === queued) {
    showApprovalCard(island, queued, true);
    return "shown";
  }
  // Waiting in line: the badge marks the pill, the chime says something else
  // arrived while a card is up — and the card's "1 of N" and source label
  // re-sync since the line behind it just grew.
  Sound.play("approval");
  syncBadge(queued.pillId);
  const head = queue.head;
  if (head && State.pendingApproval?.id === head.id) showApprovalCard(island, head, false);
  return "queued";
}

/**
 * The card has its answer (Allow, Deny, a picked question option, or "answer
 * in terminal" after the decline was already sent): the head leaves the queue
 * and the next request takes the card. Called by the island after it has sent
 * the decision.
 */
export function settleApproval(island: Island): void {
  const head = queue.head;
  const pillId = head?.pillId ?? State.pendingApproval?.pillId ?? "";
  if (head) removeEntry(head);
  refreshApprovals(island, pillId);
}

/**
 * Entries made moot by a later hook event of the same agent — a turn over,
 * or the PostToolUse of the very tool call the request asked about. Matching
 * is per request (session + pill, plus tool and input for PostToolUse), so a
 * parallel session's events never drop a card that is not theirs.
 */
export function resolveApprovals(
  island: Island,
  event: string,
  sessionId: string,
  pillId: string,
  tool: string,
  inputKey: string,
): void {
  const resolved = queue.resolved(event, sessionId, pillId, tool, inputKey);
  if (resolved.length === 0) return;
  const headId = queue.head?.id;
  let releasedPill = "";
  let headGone = false;
  for (const entry of resolved) {
    removeEntry(entry);
    // Released without a decision: the hook prints "ask" and the agent asks
    // in its own terminal.
    if (entry.requestId) void Bridge.approvalDecline(entry.requestId);
    releasedPill = entry.pillId;
    if (entry.id === headId) headGone = true;
    syncBadge(entry.pillId);
  }
  if (headGone) refreshApprovals(island, releasedPill);
  else {
    // A line-mate left: the head keeps the card but its "1 of N" shrank.
    const head = queue.head;
    if (head && State.pendingApproval?.id === head.id) showApprovalCard(island, head, false);
    State.notify();
  }
}

/** Test seam: the wait line, its deadlines and the shown card start cold. */
export function resetApprovals(): void {
  for (const timer of timers.values()) window.clearTimeout(timer);
  timers.clear();
  queue.clear();
  State.pendingApproval = null;
  State.isPinned = false;
  State.focusBeforeApproval = null;
}

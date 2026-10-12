// The wait line of permission requests (#157). Pure FIFO, no I/O: approvals.ts owns the timers, the bridge calls and the
// island, and mutates this value only. The head is the request the card shows;
// State.pendingApproval is always a projection of it.

import type { AskedQuestion } from "../core/state";

export interface QueuedApproval {
  /** Internal queue id — a decision only ever applies to this entry. */
  id: string;
  /** The relay's request id ("" when the payload carried none). */
  requestId: string;
  sessionId: string;
  /** "integration_claude", "agent_cursor" or "agent_<agent>". */
  pillId: string;
  tool: string;
  command: string;
  /** The tool's own one-line explanation (Codex sends tool_input.description). */
  description?: string;
  /** Set when the request is an AskUserQuestion rather than a permission. */
  questions?: AskedQuestion[];
  /** tool_input serialized with sorted keys, "" if absent — matches PostToolUse. */
  inputKey: string;
}

export class ApprovalQueue {
  /**
   * Upper bound of simultaneously pending requests. Each one holds a hook
   * waiting on its 110 s deadline and the card only shows one at a time, so
   * beyond this the newest falls back to its terminal.
   */
  static readonly maxPending = 5;

  private list: QueuedApproval[] = [];

  get head(): QueuedApproval | undefined {
    return this.list[0];
  }
  get count(): number {
    return this.list.length;
  }
  get isEmpty(): boolean {
    return this.list.length === 0;
  }
  get entries(): readonly QueuedApproval[] {
    return this.list;
  }

  /** The entry carrying this relay request id, if still waiting. */
  byRequestId(requestId: string): QueuedApproval | undefined {
    if (!requestId) return undefined;
    return this.list.find((e) => e.requestId === requestId);
  }

  /** 1-based position of the entry in the queue, 0 if absent. */
  position(id: string): number {
    return this.list.findIndex((e) => e.id === id) + 1;
  }

  /** True when the queued requests do not all come from the same session and agent. */
  get hasMixedSources(): boolean {
    const first = this.list[0];
    if (!first) return false;
    return this.list.some((e) => e.sessionId !== first.sessionId || e.pillId !== first.pillId);
  }

  hasEntries(pillId: string): boolean {
    return this.list.some((e) => e.pillId === pillId);
  }

  enqueue(entry: QueuedApproval, maxPending = ApprovalQueue.maxPending): "accepted" | "rejectedFull" {
    if (this.list.length >= maxPending) return "rejectedFull";
    this.list.push(entry);
    return "accepted";
  }

  /** Removes only the entry with this id. Other entries keep their order. */
  remove(id: string): QueuedApproval | undefined {
    const at = this.list.findIndex((e) => e.id === id);
    if (at < 0) return undefined;
    return this.list.splice(at, 1)[0];
  }

  /**
   * Entries made moot by a later hook event of the same agent. Matching is per
   * request (session + agent, plus tool and input for PostToolUse), never by
   * pill alone.
   */
  resolved(
    event: string,
    sessionId: string,
    pillId: string,
    tool: string,
    inputKey: string,
  ): QueuedApproval[] {
    switch (event) {
      case "PostToolUse":
      case "PostToolUseFailure":
        return this.list.filter(
          (e) =>
            e.pillId === pillId &&
            e.sessionId === sessionId &&
            e.tool === tool &&
            // A question answered in the terminal may echo without its input:
            // session and tool name are match enough. A permission demands the
            // exact input it asked about.
            (e.questions != null || e.inputKey === inputKey),
        );
      case "Stop":
      case "StopFailure":
      case "UserPromptSubmit":
      case "SessionEnd":
      case "Interrupt":
        return this.list.filter((e) => e.pillId === pillId && e.sessionId === sessionId);
      default:
        return [];
    }
  }

  clear(): void {
    this.list = [];
  }
}

/**
 * tool_input serialized with sorted keys, "" if absent or empty — the same
 * shape PostToolUse later carries, so a finished tool call resolves only the
 * request that asked about it.
 */
export function approvalInputKey(input: Record<string, unknown>): string {
  if (Object.keys(input).length === 0) return "";
  const stable = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(stable);
    if (v !== null && typeof v === "object") {
      const rec = v as Record<string, unknown>;
      return Object.fromEntries(
        Object.keys(rec)
          .sort()
          .map((k) => [k, stable(rec[k])]),
      );
    }
    return v;
  };
  return JSON.stringify(stable(input));
}

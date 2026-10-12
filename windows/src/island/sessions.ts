// The live agent sessions behind each pill (#245).
//
// A pill is picked from the client that sent the event — the terminal app or
// `coucou_agent` — never from the session. Two `claude` started in two projects
// under VS Code therefore land on the same `integration_claude`, while
// `State.tasks` holds one entry per pill. Without a session set, the first
// session to end wipes the card and the diffs the second one is still filling.

/** What a pill shows while a session owns it. */
export interface SessionDisplay {
  session: string;
  projectName: string;
  cwd: string;
}

interface LiveSession {
  projectName: string;
  cwd: string;
  isWorking: boolean;
  lastSeen: number;
  /** The relay's clock (`coucou_ts`) at this session's last Stop, when it sent one. */
  endedAt?: number;
}

interface PillSessions {
  /** Live sessions, oldest first. The first one owns name and cwd. */
  order: string[];
  sessions: Map<string, LiveSession>;
}

/** How far a terminal event is allowed to reach. */
export type TerminalScope = "pill" | "sessionOnly";

export class SessionRegistry {
  /**
   * A session unheard of for this long counts as gone. A `SessionEnd` that
   * never arrives — a killed terminal, a crash — would otherwise pin a card
   * to a session nobody is running any more.
   */
  static readonly maxSilence = 12 * 3_600_000;

  /**
   * A session mid-turn emits a hook event every few seconds, so this long
   * without one means its `Stop` went missing. Stops counting it as working,
   * which is what keeps a sibling session from staying stuck out of its
   * finished state. Longer than any tool call an agent will wait on.
   */
  static readonly maxTurnSilence = 30 * 60_000;

  private pills = new Map<string, PillSessions>();

  /**
   * Records the session that sent an event as live behind `pill`. `working`
   * says whether the event means the session is mid-turn: a `PreToolUse` does,
   * a `SessionStart` or a stray notification does not. The flag is sticky —
   * only `endTurn` lifts it — so a quiet event mid-turn cannot idle it away.
   */
  note(pill: string, display: SessionDisplay, working: boolean, now = Date.now()): void {
    const p: PillSessions = this.pills.get(pill) ?? { order: [], sessions: new Map() };
    sweep(p, now);
    // An event that names no session leaves no trace here: it still reaches
    // the pill through ensurePill, but session-scoped teardown needs an id to
    // attribute — an anonymous SessionEnd must not count as a third session.
    if (display.session !== "") {
      if (!p.sessions.has(display.session)) p.order.push(display.session);
      const s = p.sessions.get(display.session) ?? {
        projectName: display.projectName,
        cwd: display.cwd,
        isWorking: false,
        lastSeen: now,
      };
      s.projectName = display.projectName;
      if (display.cwd) s.cwd = display.cwd;
      if (working) s.isWorking = true;
      s.lastSeen = now;
      p.sessions.set(display.session, s);
    }
    if (p.order.length === 0) this.pills.delete(pill);
    else this.pills.set(pill, p);
  }

  /**
   * Ends a session's turn without ending the session: a `Stop` closes a turn,
   * and the user can send another prompt right after. A session we have never
   * seen stays untracked — Coucou can start in the middle of one.
   */
  endTurn(pill: string, session: string, now = Date.now(), relayTs?: number): TerminalScope {
    const p = this.pills.get(pill) ?? { order: [], sessions: new Map() };
    sweep(p, now);
    // An event that names no session cannot be picked out of a crowd, but a
    // lone live session can only be that one — keep the old single-session
    // teardown while siblings stay scoped to their own id.
    const s =
      p.sessions.get(session) ??
      (session === "" && p.order.length === 1 ? p.sessions.get(p.order[0]) : undefined);
    if (s) {
      s.isWorking = false;
      s.lastSeen = now;
      if (relayTs !== undefined) s.endedAt = relayTs;
    }
    if (p.order.length === 0) this.pills.delete(pill);
    else this.pills.set(pill, p);
    return [...p.sessions.values()].some((x) => x.isWorking) ? "sessionOnly" : "pill";
  }

  /**
   * Drops a session for good. `.pill` only when it was the last one live, so
   * the card and the diffs survive a sibling session ending.
   */
  endSession(pill: string, session: string, now = Date.now()): TerminalScope {
    const p = this.pills.get(pill) ?? { order: [], sessions: new Map() };
    sweep(p, now);
    // Same anonymous-event rule as endTurn: with exactly one live session an
    // unattributed `SessionEnd` can only be that session's.
    const target = !p.sessions.has(session) && session === "" && p.order.length === 1 ? p.order[0] : session;
    p.order = p.order.filter((s) => s !== target);
    p.sessions.delete(target);
    if (p.order.length === 0) {
      this.pills.delete(pill);
      return "pill";
    }
    this.pills.set(pill, p);
    return "sessionOnly";
  }

  /**
   * The session whose project name and cwd the pill shows. Ownership goes to
   * the oldest live session and only moves on when that one ends, so a single
   * name field stops flipping between two parallel sessions.
   */
  displayOwner(pill: string): SessionDisplay | null {
    const p = this.pills.get(pill);
    const id = p?.order[0];
    const s = id != null ? p?.sessions.get(id) : undefined;
    return id != null && s ? { session: id, projectName: s.projectName, cwd: s.cwd } : null;
  }

  /**
   * Whether this session may write the pill's name and cwd. True when the pill
   * has no live session yet, so a first event is never dropped.
   */
  ownsDisplay(pill: string, session: string): boolean {
    const owner = this.displayOwner(pill);
    if (!owner) return true;
    return owner.session === session;
  }

  liveCount(pill: string): number {
    return this.pills.get(pill)?.order.length ?? 0;
  }

  workingCount(pill: string): number {
    const p = this.pills.get(pill);
    if (!p) return 0;
    return [...p.sessions.values()].filter((s) => s.isWorking).length;
  }

  /**
   * True for an event its relay stamped before this session's last Stop: each
   * event has its own relay process, and a quick one can overtake a slow one,
   * so a turn's last PostToolUse may reach the island after its Stop.
   */
  sentBeforeTurnEnded(pill: string, session: string, relayTs: number): boolean {
    const endedAt = this.pills.get(pill)?.sessions.get(session)?.endedAt;
    return endedAt !== undefined && relayTs < endedAt;
  }

  clear(): void {
    this.pills.clear();
  }
}

function sweep(pill: PillSessions, now: number): void {
  for (const [id, session] of [...pill.sessions]) {
    const silence = now - session.lastSeen;
    if (silence > SessionRegistry.maxSilence) {
      pill.sessions.delete(id);
      pill.order = pill.order.filter((s) => s !== id);
    } else if (session.isWorking && silence > SessionRegistry.maxTurnSilence) {
      session.isWorking = false;
    }
  }
}

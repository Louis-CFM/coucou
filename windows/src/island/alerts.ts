// Alert pinning: a card the user has to see (finished, error, approval,
// question, approval notice, the first-launch setup offer) opens the island and keeps it open until the
// user acts on it. No DOM here, so the fixture can drive it with fake timers.

import { State } from "../core/state";
import type { IslandViewName } from "../core/layout";
import type { IslandStateMachine } from "./fsm";

export const ALERT_VIEWS: ReadonlySet<IslandViewName> = new Set<IslandViewName>([
  "finished", "error", "approval", "question", "notice", "setupOffer",
]);

/**
 * The compact island must not hide while something is still unacknowledged:
 * a pinned card, or a badge on a pill (alerts that queued behind another).
 */
export function keepIslandVisible(): boolean {
  // Integration pollers (Stripe, GitHub…) only reveal; their badges clear on a timer.
  return State.isPinned || State.tasks.some((t) => !!t.pillBadge && (!t.isIntegration || t.source === "claudeCode"));
}

export class AlertGate {
  constructor(private fsm: IslandStateMachine) {
    fsm.keepVisible = keepIslandVisible;
  }

  /** Opens the island for `view`. Alert views pin it; other views keep the current pin. */
  open(view: IslandViewName) {
    if (ALERT_VIEWS.has(view)) State.isPinned = true;
    this.fsm.pinned = State.isPinned;
    this.fsm.forceHome();
  }

  /**
   * The user acted on the card (OK, Open, a pill, a tab, Esc). A pending
   * approval stays pinned: it must be answered, not dismissed. `mouseInside`
   * false restarts the normal auto-close countdown.
   */
  acknowledge(mouseInside: boolean) {
    if (State.pendingApproval) return;
    const wasPinned = State.isPinned || this.fsm.pinned;
    State.isPinned = false;
    this.fsm.pinned = false;
    if (wasPinned && !mouseInside) this.fsm.mouseLeft();
  }

  /**
   * An approval stopped waiting (answered elsewhere, timed out, session
   * ended): with the mouse away, the normal auto-close starts again.
   */
  drop(mouseInside = false) {
    this.fsm.pinned = State.isPinned;
    if (!this.fsm.pinned && !mouseInside) this.fsm.mouseLeft();
  }
}

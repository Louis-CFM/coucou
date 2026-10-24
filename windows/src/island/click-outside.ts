// When a click outside should fold the island. Rust reports the press and the
// release of a left click that began outside (island.rs); this decides whether
// the island folds, and Island does the folding with the rules Esc uses.

/** A press this soon after an automatic open is the user clicking away from the
 *  window that was in front, not a reply to the island. */
export const AUTO_OPEN_GRACE_MS = 1000;

export class ClickOutside {
  private pressed: { at: number; expanded: boolean } | null = null;

  /** A left press began outside the island. `expanded`: it is fully open now. */
  press(now: number, expanded: boolean) {
    this.pressed = { at: now, expanded };
  }

  /** The island changed mode: a press made before it no longer counts. */
  clear() {
    this.pressed = null;
  }

  /**
   * The press ended outside the island too. True when the island should fold.
   * `lastAutoOpenAt`: when a hook last opened it by itself (`-Infinity` for never).
   */
  release(enabled: boolean, expanded: boolean, lastAutoOpenAt: number): boolean {
    const press = this.pressed;
    this.pressed = null;
    if (!press || !enabled || !expanded || !press.expanded) return false;
    return press.at - lastAutoOpenAt >= AUTO_OPEN_GRACE_MS;
  }
}

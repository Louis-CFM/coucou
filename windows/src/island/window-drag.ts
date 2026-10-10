// The gesture that moves the island: where a press may start, and when it becomes a drag.
// Rust then carries the window (src-tauri/src/island/placement.rs).

import type { IslandMode, IslandViewName } from "../core/layout";

/** CSS (= logical) px from the press: below that, nothing starts. Equal to MIN_MOVE (placement.rs), which cancels a drop that close: keep in sync. */
export const WINDOW_DRAG_THRESHOLD = 8;

export interface GrabContext {
  capable: boolean;     // the platform can put the island anywhere
  mode: IslandMode;
  view: IslandViewName;
  mochiMoving: boolean; // Mochi carried or flying (DesktopLink.moving)
  onBot: boolean;       // the press is on Mochi's disc: this gesture takes him out to the desktop
  onBar: boolean;       // the empty part of the top bar, or the margin of #content
}

/**
 * The empty part of the top bar: #header itself, its .tabs and .header-actions rows (direct
 * children), or the margin of #content. Tabs, buttons and pills sit one level lower.
 */
export function isBarTarget(target: Element, header: Element, content: Element): boolean {
  return target === header || target.parentElement === header || target === content;
}

/** The whole small island (nothing on it is clickable), or the empty part of the open island's bar. */
export function canGrab(c: GrabContext): boolean {
  if (!c.capable || c.mochiMoving || c.onBot) return false;
  if (c.mode === "compact") return true;
  if (c.mode !== "expanded" || !c.onBar) return false;
  return c.view !== "greeting" && c.view !== "confused"; // no visible header
}

export class WindowDragGesture {
  private from: { x: number; y: number } | null = null;
  get armed(): boolean { return this.from !== null; }
  press(x: number, y: number) { this.from = { x, y }; }
  reset() { this.from = null; }
  /** The press point, ONCE: the main button still down and the pointer out of the dead zone. */
  move(x: number, y: number, buttons: number): { x: number; y: number } | null {
    const from = this.from;
    if (!from) return null;
    if (!(buttons & 1)) { this.from = null; return null; }
    if (Math.hypot(x - from.x, y - from.y) < WINDOW_DRAG_THRESHOLD) return null;
    this.from = null;
    return from;
  }
}

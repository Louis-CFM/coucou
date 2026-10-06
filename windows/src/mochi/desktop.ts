// Desktop Mochi — pure geometry and lifecycle rules.
//
// Port of DesktopMochiLogic.swift from the macOS app. None of it touches a
// window: every rule that can be decided from numbers alone lives here so it can
// be tested, and so the same decisions are made on Windows and macOS rather
// than drifting apart.
//
// One deliberate difference from the Swift: `clampOrigin` takes the work area as
// plain min/max numbers in screen coordinates rather than a CGRect, and treats
// the y axis as increasing downward. AppKit's `visibleFrame` is y-up; Windows
// virtual-screen coordinates are y-down. Converting in the middle of this file
// would have been the easiest place to get a sign wrong, so the conversion
// happens once at the call site in Rust instead.

/** Phase of the desktop Mochi lifecycle. */
export type DesktopPhase =
  /** No panel on screen. */
  | "home"
  /** Animating from the notch to the saved desktop position. */
  | "flyingOut"
  /** Live on the desktop — the normal state. */
  | "onDesktop"
  /** An alert arrived; animating toward the notch. */
  | "retracting"
  /** The alert cleared while the retract was still running. */
  | "alertResolvedDuringRetract"
  /** Retract finished; the island is showing the alert. */
  | "atNotchForAlert";

export const DESKTOP_PANEL_SIZE = 120;
export const DESKTOP_PANEL_SIZE_MIN = 72;
export const DESKTOP_PANEL_SIZE_MAX = 240;
export const DESKTOP_SLEEP_TIMEOUT_MS = 120_000;
export const DESKTOP_SLEEP_MOUSE_DISTANCE = 150;
/** Gap kept between the panel and the edge of the work area. */
export const DESKTOP_CLAMP_MARGIN = 24;
/**
 * Body radius as a fraction of the panel.
 *
 * The panel is square and transparent; only this circle is the bot. Anything
 * outside it has to be click-through, or the invisible corners of the window
 * would swallow clicks meant for whatever is underneath.
 */
export const DESKTOP_BODY_RADIUS_FRACTION = 0.24;

/** A work area in screen coordinates, y increasing downward. */
export interface WorkArea {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/** Whether Mochi should fall asleep. */
export function shouldSleep(
  lastAgentActiveMs: number,
  mouseDistanceToPanelCenter: number,
): boolean {
  return (
    lastAgentActiveMs > DESKTOP_SLEEP_TIMEOUT_MS &&
    mouseDistanceToPanelCenter >= DESKTOP_SLEEP_MOUSE_DISTANCE
  );
}

/**
 * Hit-test the circular body inside the square panel.
 *
 * `local` is relative to the panel's top-left, y increasing downward.
 */
export function isOverBody(
  localX: number,
  localY: number,
  panelSize = DESKTOP_PANEL_SIZE,
): boolean {
  const cx = panelSize / 2;
  const r = panelSize * DESKTOP_BODY_RADIUS_FRACTION;
  const dx = localX - cx;
  const dy = localY - cx;
  return dx * dx + dy * dy <= r * r;
}

/**
 * Where Mochi looks, in the same space as the tracked mouse.
 *
 * The Swift subtracts the screen origin and flips y because AppKit counts up
 * from the bottom. Here the screen origin is already relative, so only the
 * centre is added.
 */
export function lookOrigin(panelMinX: number, panelMinY: number, panelSize = DESKTOP_PANEL_SIZE) {
  return { x: panelMinX + panelSize / 2, y: panelMinY + panelSize / 2 };
}

/** Whether Mochi should retract the moment it lands, if an alert fired mid-flight. */
export function shouldRetractOnLanding(alertActive: boolean): boolean {
  return alertActive;
}

/**
 * Clamps a panel origin so the whole panel stays inside `area` with `margin` to
 * spare on every side.
 *
 * If the work area is smaller than the panel plus both margins the clamp range
 * inverts; without the guard below `Math.min`/`Math.max` would return the
 * *upper* bound and park the panel off the right edge. Narrow side-by-side
 * displays hit this for real.
 */
export function clampOrigin(
  originX: number,
  originY: number,
  area: WorkArea,
  panelSize = DESKTOP_PANEL_SIZE,
  margin = DESKTOP_CLAMP_MARGIN,
): { x: number; y: number } {
  const minX = area.left + margin;
  const maxX = area.right - panelSize - margin;
  const minY = area.top + margin;
  const maxY = area.bottom - panelSize - margin;
  return {
    x: maxX < minX ? minX : Math.min(Math.max(originX, minX), maxX),
    y: maxY < minY ? minY : Math.min(Math.max(originY, minY), maxY),
  };
}

/** Where Mochi lands the first time it is shown, before anything is persisted. */
export function defaultOrigin(
  area: WorkArea,
  panelSize = DESKTOP_PANEL_SIZE,
  margin = DESKTOP_CLAMP_MARGIN,
): { x: number; y: number } {
  // Bottom-right of the work area, in the margin: out of the way, and the
  // spot people reach for first when dragging it somewhere.
  return clampOrigin(area.right - panelSize - margin, area.bottom - panelSize - margin, area, panelSize, margin);
}

/**
 * The next phase after a landing, given whether an alert is waiting.
 *
 * Swift handles this inline in the animation completion; it is pulled out here
 * because "an approval landed while the panel was still flying" is exactly the
 * case that silently regressed on macOS once already.
 */
export function phaseAfterLanding(alertActive: boolean): DesktopPhase {
  return shouldRetractOnLanding(alertActive) ? "atNotchForAlert" : "onDesktop";
}
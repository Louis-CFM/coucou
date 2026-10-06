// Desktop Mochi logic — ported from DesktopMochiLogic.swift.
//
// The macOS side has no tests for this; every rule was verified by watching a
// window move. These are the same five rules plus the two edge cases that were
// only ever discovered by a user with a second monitor.

import {
  DESKTOP_BODY_RADIUS_FRACTION,
  DESKTOP_CLAMP_MARGIN,
  DESKTOP_PANEL_SIZE,
  DESKTOP_SLEEP_MOUSE_DISTANCE,
  DESKTOP_SLEEP_TIMEOUT_MS,
  clampOrigin,
  defaultOrigin,
  isOverBody,
  lookOrigin,
  phaseAfterLanding,
  shouldRetractOnLanding,
  shouldSleep,
  type WorkArea,
} from "../src/mochi/desktop";

let failures = 0;
const check = (name: string, got: unknown, want: unknown) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures++;
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${name}`);
  if (!ok) console.log(`        got  ${JSON.stringify(got)}\n        want ${JSON.stringify(want)}`);
};

// A 1920x1080 screen with a taskbar along the bottom.
const SCREEN: WorkArea = { left: 0, top: 0, right: 1920, bottom: 1040 };

console.log("constants match the macOS build");
check("panel size", DESKTOP_PANEL_SIZE, 120);
check("sleep timeout", DESKTOP_SLEEP_TIMEOUT_MS, 120_000);
check("sleep mouse distance", DESKTOP_SLEEP_MOUSE_DISTANCE, 150);
check("clamp margin", DESKTOP_CLAMP_MARGIN, 24);
check("body radius fraction", DESKTOP_BODY_RADIUS_FRACTION, 0.24);

// ── sleep ────────────────────────────────────────────────────────────────────
console.log("\nsleeping needs both time and distance");
check("idle and mouse far -> sleep", shouldSleep(121_000, 200), true);
check("idle but mouse close -> awake", shouldSleep(121_000, 10), false);
check("recent but mouse far -> awake", shouldSleep(5_000, 900), false);
check("exactly at the timeout is not yet", shouldSleep(DESKTOP_SLEEP_TIMEOUT_MS, 900), false);
check("exactly at the distance counts as far", shouldSleep(121_000, DESKTOP_SLEEP_MOUSE_DISTANCE), true);

// ── hit testing ─────────────────────────────────────────────────────────────
console.log("\nonly the circle is the bot");
check("dead centre is over the body", isOverBody(60, 60), true);
check("corner is not", isOverBody(2, 2), false);
check("edge midpoint is not", isOverBody(60, 1), false);
// 120 * 0.24 = 28.8 radius
check("just inside the radius", isOverBody(60 + 28, 60), true);
check("just outside the radius", isOverBody(60 + 30, 60), false);
// The panel is square and mostly transparent; a click in the corner must pass
// through to whatever is underneath, or the window eats clicks across a 120px
// square of desktop.
check("the empty corners stay click-through", isOverBody(10, 110), false);

// ── eye tracking ────────────────────────────────────────────────────────────
console.log("\neye origin is the panel centre in screen space");
check("at 100,200", lookOrigin(100, 200), { x: 160, y: 260 });

// ── clamping ────────────────────────────────────────────────────────────────
console.log("\nclamping keeps the whole panel inside the work area");
{
  const at = clampOrigin(0, 0, SCREEN);
  check("top-left is pushed in", at, { x: 24, y: 24 });
}
{
  const at = clampOrigin(99999, 99999, SCREEN);
  // 1920 - 120 - 24 = 1776 ; 1040 - 120 - 24 = 896
  check("far off-screen is pulled back", at, { x: 1776, y: 896 });
}
{
  const at = clampOrigin(500, 500, SCREEN);
  check("a legal position is left alone", at, { x: 500, y: 500 });
}
{
  // A second monitor to the right, as Windows reports virtual-screen coords.
  const second: WorkArea = { left: 1920, top: 0, right: 3840, bottom: 1040 };
  const at = clampOrigin(2000, 300, second);
  check("offsets on a second display are respected", at, { x: 2000, y: 300 });
  const pulled = clampOrigin(100, 100, second);
  // x is pulled to 1920+24; y=100 is already legal on that display, so it stays.
  check("x is clamped against that display's left edge", pulled.x, 1944);
  check("a legal y on the second display is left alone", pulled.y, 100);
}

console.log("\nnarrow work areas do not invert the clamp");
{
  // The clamp range inverts once the work area is narrower than the panel plus
  // both margins (120 + 24 * 2 = 168px). A strip display is a real thing to have
  // beside a laptop, and without the guard in clampOrigin `Math.min(Math.max(x,
  // minX), maxX)` returns maxX — parking the panel off the right edge, which is
  // where it would be invisible and unreachable.
  const strip: WorkArea = { left: 0, top: 0, right: 160, bottom: 480 };
  check("this width really does invert", strip.right - DESKTOP_PANEL_SIZE - DESKTOP_CLAMP_MARGIN < DESKTOP_CLAMP_MARGIN, true);
  const at = clampOrigin(900, 400, strip);
  check("x falls back to the lower bound", at.x, 24);
  check("y is still clamped normally", at.y, 336);
}
{
  // One pixel wider and the range is valid again: 170 - 120 - 24 = 26.
  const justWideEnough: WorkArea = { left: 0, top: 0, right: 170, bottom: 480 };
  const at = clampOrigin(900, 400, justWideEnough);
  check("a valid narrow range clamps to its upper bound", at.x, 26);
}
{
  const tiny: WorkArea = { left: 0, top: 0, right: 100, bottom: 100 };
  const at = clampOrigin(50, 50, tiny);
  check("absurdly small work area does not produce NaN", Number.isFinite(at.x) && Number.isFinite(at.y), true);
}

// ── landing ─────────────────────────────────────────────────────────────────
console.log("\nlanding with an alert already waiting");
check("no alert -> on the desktop", phaseAfterLanding(false), "onDesktop");
check("alert fired mid-flight -> back to the notch", phaseAfterLanding(true), "atNotchForAlert");
check("matches the Swift one-liner", shouldRetractOnLanding(true), phaseAfterLanding(true) === "atNotchForAlert");

// ── default placement ───────────────────────────────────────────────────────
console.log("\ndefault placement");
{
  const at = defaultOrigin(SCREEN);
  check("bottom-right, inset by the margin", at, { x: 1776, y: 896 });
  check("inside the work area", at.x >= 0 && at.y >= 0 && at.x + DESKTOP_PANEL_SIZE <= SCREEN.right && at.y + DESKTOP_PANEL_SIZE <= SCREEN.bottom, true);
}

console.log(failures === 0 ? "\n  all pass" : `\n  ${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
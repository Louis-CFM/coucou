// Mochi on the desktop: the pure logic and the life cycle (src/mochi/desktop-logic.ts).
// The first half mirrors tests/DesktopMochiTests.swift; the geometry of the
// window itself (clamping, saved spots, the island's home zone) is tested in
// src-tauri/src/desktop.rs, where it lives.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  BODY_RADIUS_FRACTION, DesktopMochiController, PANEL_SIZE, RETRACT_DELAY_MS, RETURN_DELAY_MS,
  agentActive, alertActive, gaze, isOverBody, layerDragTopLeft, lookOrigin, pointerDistance,
  shouldRetractOnLanding, shouldSleep, windowDragTopLeft,
} from "../src/mochi/desktop-logic.ts";

// ── shouldSleep ───────────────────────────────────────────────────────────────

test("shouldSleep: idle long enough and the pointer far away", () => {
  assert.equal(shouldSleep(5, 300), false, "active agent must not sleep");
  assert.equal(shouldSleep(200, 50), false, "mouse near panel must not sleep");
  assert.equal(shouldSleep(200, 200), true, "long idle + far mouse must sleep");
  assert.equal(shouldSleep(120, 300), false, "exactly at timeout must not sleep");
  assert.equal(shouldSleep(120.1, 300), true, "just over timeout must sleep");
  assert.equal(shouldSleep(200, 150), true, "at distance threshold must sleep");
});

test("agent work keeps him awake, idle and sleeping don't", () => {
  for (const s of ["working", "thinking", "searching", "approval", "question", "finished", "error"]) {
    assert.equal(agentActive(s), true, s);
  }
  assert.equal(agentActive("idle"), false);
  assert.equal(agentActive("sleeping"), false);
});

test("pointer distance: measured with a cursor poll, remembered without one", () => {
  assert.equal(pointerDistance(true, { x: 60, y: 60 }, 0), 0);
  assert.equal(pointerDistance(true, { x: 60 + 150, y: 60 }, 0), 150);
  assert.equal(pointerDistance(true, null, 0), Infinity, "no cursor yet: far");
  // Linux: near while the pointer was over him a moment ago.
  assert.equal(pointerDistance(false, null, 100), 0);
  assert.equal(pointerDistance(false, { x: 60, y: 60 }, 60_000), Infinity);
});

// ── isOverBody ────────────────────────────────────────────────────────────────

test("isOverBody: the round body, not the square window", () => {
  const s = 120;
  const r = s * BODY_RADIUS_FRACTION; // 28.8
  assert.equal(isOverBody({ x: 60, y: 60 }, s), true, "center must be inside body");
  assert.equal(isOverBody({ x: 60 + r - 0.5, y: 60 }, s), true, "inside radius must hit");
  assert.equal(isOverBody({ x: 60 + r + 0.5, y: 60 }, s), false, "outside radius must miss");
  assert.equal(isOverBody({ x: 0, y: 0 }, s), false, "corner must miss");
  const diag = r / Math.SQRT2 - 0.5;
  assert.equal(isOverBody({ x: 60 + diag, y: 60 + diag }, s), true, "diagonal inside must hit");
  assert.equal(PANEL_SIZE, 120);
});

// ── lookOrigin / gaze ─────────────────────────────────────────────────────────

const sign = (v) => (v === 0 ? 0 : v < 0 ? -1 : 1);

/** The Mac test's AppKit points (y up from the menu-bar screen's bottom) → y down. */
const topDown = (p, desktopTop) => ({ x: p.x, y: desktopTop - p.y });

test("lookOrigin: the window centre, in desktop coordinates", () => {
  // Panel at (200, 300) from the top-left of the desktop.
  assert.deepEqual(lookOrigin(200, 300, 120), { x: 260, y: 360 });
  // On a secondary screen to the right: x stays global, not screen-relative.
  assert.deepEqual(lookOrigin(1540, 100, 120), { x: 1600, y: 160 });
});

test("gaze signs across a real arrangement of screens", () => {
  // Menu-bar MacBook 1512×982 at (0,0); external 2560×1440 above it at
  // (-500, 982); portrait 1080×1920 on the left at (-1080, -600). AppKit
  // coordinates as in the Swift test, turned y-down like a PC reports them.
  const top = 982;
  const look = (bot, mouse) => {
    const g = gaze(topDown(bot, top), topDown(mouse, top));
    return [sign(g.lookX), sign(g.lookY)];
  };
  // Mochi in the island at the top of the external screen above.
  const islandOnTop = { x: 780, y: 2422 - 16 };
  assert.deepEqual(look(islandOnTop, { x: 1400, y: 100 }), [1, -1], "cursor on the MacBook below-right");
  assert.deepEqual(look(islandOnTop, { x: -1000, y: 0 }), [-1, -1], "cursor on the portrait screen");
  assert.deepEqual(look(islandOnTop, { x: 780, y: 2500 }), [0, 1], "cursor above Mochi");
  // Mochi on the desktop of the portrait screen, cursor on the external screen above.
  const panelMin = topDown({ x: -700, y: -200 + 120 }, top); // AppKit minY is the bottom edge
  const desktopOnLeft = lookOrigin(panelMin.x, panelMin.y, 120);
  const mouseAbove = topDown({ x: 1000, y: 2000 }, top);
  assert.ok(mouseAbove.x > desktopOnLeft.x && mouseAbove.y < desktopOnLeft.y,
    "desktop Mochi looks right and up at a cursor on another screen");
  const g = gaze(desktopOnLeft, mouseAbove);
  assert.ok(g.lookX > 0 && g.lookY > 0);
});

// ── shouldRetractOnLanding / alerts ───────────────────────────────────────────

test("shouldRetractOnLanding", () => {
  assert.equal(shouldRetractOnLanding(true), true, "must retract when alert is active on landing");
  assert.equal(shouldRetractOnLanding(false), false, "must not retract when no alert on landing");
});

test("a permission or a question sends him back to the island", () => {
  assert.equal(alertActive({ pendingApproval: null, tasks: [{ state: "working" }] }), false);
  assert.equal(alertActive({ pendingApproval: { requestId: "r" }, tasks: [] }), true);
  assert.equal(alertActive({ pendingApproval: null, tasks: [{ state: "idle" }, { state: "question" }] }), true);
  // The question card (#216) is the same card with `questions`: it flies him home too.
  const question = {
    requestId: "q", sessionId: "s", pillId: "integration_claude", tool: "AskUserQuestion", command: "",
    questions: [{ question: "Which?", options: [{ label: "A", description: "" }], multiSelect: false }],
  };
  assert.equal(alertActive({ pendingApproval: question, tasks: [{ state: "idle" }] }), true);
  // Any agent's permission card counts, Codex's included.
  assert.equal(alertActive({ pendingApproval: { requestId: "r", pillId: "agent_codex" }, tasks: [] }), true);
});

// ── Linux drags ───────────────────────────────────────────────────────────────

test("layer-shell drag: display coordinates once the overlay is up", () => {
  const origin = { x: 500, y: 300 };
  const grab = { x: 60, y: 62 };
  // Not applied yet: the pointer is still relative to the small surface.
  assert.deepEqual(layerDragTopLeft(origin, { x: 70, y: 62 }, grab, false), { x: 510, y: 300 });
  // Applied: the pointer reads in display coordinates.
  assert.deepEqual(layerDragTopLeft(origin, { x: 900, y: 462 }, grab, true), { x: 840, y: 400 });
});

test("X11 drag: screen delta, in physical pixels", () => {
  assert.deepEqual(
    windowDragTopLeft({ x: 1000, y: 600 }, { x: 520, y: 310 }, { x: 500, y: 300 }, 2),
    { x: 1040, y: 620 },
  );
});

// ── Life cycle ────────────────────────────────────────────────────────────────

/** A world the controller acts on, with manual flights and timers. */
function world({ alert = false, flyOutOk = true } = {}) {
  const log = [];
  const timers = [];
  const flights = [];
  const w = {
    alert,
    away: false,
    log,
    /** Lands the oldest pending flight. */
    async land(result) {
      const f = flights.shift();
      assert.ok(f, "a flight should be in the air");
      f.resolve(result ?? f.defaultResult);
      await new Promise((r) => setImmediate(r));
    },
    get flying() {
      return flights.map((f) => f.kind);
    },
    /** Runs the timers due within `ms`. */
    async tick(ms) {
      const due = timers.filter((t) => t.ms <= ms);
      for (const t of due) timers.splice(timers.indexOf(t), 1);
      for (const t of due) t.fn();
      await new Promise((r) => setImmediate(r));
    },
    port: {
      flyOut: (anywhere) => {
        log.push(anywhere ? "out-anywhere" : "out-spot");
        return new Promise((resolve) => flights.push({ kind: "out", resolve, defaultResult: flyOutOk }));
      },
      flyHome: (forget) => {
        log.push(forget ? "home-forget" : "home-keep");
        return new Promise((resolve) => flights.push({ kind: "home", resolve, defaultResult: true }));
      },
      setAway: (a) => {
        w.away = a;
      },
      emote: (e) => log.push(`emote:${e}`),
      play: (s) => log.push(`sound:${s}`),
      alertActive: () => w.alert,
      revealIsland: () => log.push("reveal"),
      later: (fn, ms) => timers.push({ fn, ms }),
    },
  };
  w.c = new DesktopMochiController(w.port);
  return w;
}

test("launch: flies out to his spot only if he lives on the desktop", async () => {
  const w = world();
  await w.c.launchFlyIfNeeded();
  assert.equal(w.c.phase, "home", "not enabled: stays home");
  assert.deepEqual(w.flying, []);

  w.c.enabled = true;
  void w.c.launchFlyIfNeeded();
  assert.equal(w.c.phase, "flyingOut");
  assert.equal(w.away, true, "the island's Mochi hides as he leaves");
  await w.land();
  assert.equal(w.c.phase, "onDesktop");
});

test("launch: a spot on a display that is gone keeps him home", async () => {
  const w = world({ flyOutOk: false });
  w.c.enabled = true;
  void w.c.launchFlyIfNeeded();
  await w.land();
  assert.equal(w.c.phase, "home");
  assert.equal(w.c.enabled, false);
  assert.equal(w.away, false);
});

test("launch during an alert waits in the island, then flies out once answered", async () => {
  const w = world({ alert: true });
  w.c.enabled = true;
  w.c.updateAlert(true);
  await w.c.launchFlyIfNeeded();
  assert.equal(w.c.phase, "atNotchForAlert");
  assert.deepEqual(w.flying, []);

  w.alert = false;
  w.c.updateAlert(false);
  assert.equal(w.c.phase, "home");
  await w.tick(RETURN_DELAY_MS);
  assert.deepEqual(w.flying, ["out"]);
  await w.land();
  assert.equal(w.c.phase, "onDesktop");
});

test("alert on the desktop: surprised, flies to the island, comes back once answered", async () => {
  const w = world();
  w.c.enabled = true;
  void w.c.launchFlyIfNeeded();
  await w.land();

  w.alert = true;
  w.c.updateAlert(true);
  assert.equal(w.c.phase, "retracting");
  assert.ok(w.log.includes("emote:surprised"));
  await w.tick(RETRACT_DELAY_MS);
  assert.deepEqual(w.flying, ["home"]);
  assert.ok(w.log.includes("home-keep"), "he keeps his spot");
  await w.land();
  assert.equal(w.c.phase, "atNotchForAlert");
  assert.equal(w.away, false, "the island's Mochi shows the alert");
  assert.ok(w.log.includes("reveal"));
  assert.equal(w.c.enabled, true);

  w.alert = false;
  w.c.updateAlert(false);
  await w.tick(RETURN_DELAY_MS);
  await w.land();
  assert.equal(w.c.phase, "onDesktop");
});

test("alert answered before he takes off: he never leaves his spot", async () => {
  const w = world();
  w.c.enabled = true;
  void w.c.launchFlyIfNeeded();
  await w.land();

  w.alert = true;
  w.c.updateAlert(true);
  w.alert = false;
  w.c.updateAlert(false);
  assert.equal(w.c.phase, "alertResolvedDuringRetract");
  await w.tick(RETRACT_DELAY_MS);
  assert.equal(w.c.phase, "onDesktop");
  assert.deepEqual(w.flying, []);
});

test("alert answered during the flight to the island: straight back out", async () => {
  const w = world();
  w.c.enabled = true;
  void w.c.launchFlyIfNeeded();
  await w.land();

  w.alert = true;
  w.c.updateAlert(true);
  await w.tick(RETRACT_DELAY_MS);
  assert.deepEqual(w.flying, ["home"]);
  w.alert = false;
  w.c.updateAlert(false);
  assert.equal(w.c.phase, "alertResolvedDuringRetract");
  await w.land();
  assert.deepEqual(w.flying, ["out"], "relaunched as soon as he reached the island");
  await w.land();
  assert.equal(w.c.phase, "onDesktop");
});

test("an alert that went up during the flight out sends him right back", async () => {
  const w = world();
  w.c.enabled = true;
  void w.c.launchFlyIfNeeded();
  w.alert = true;
  w.c.updateAlert(true); // ignored mid-flight
  assert.equal(w.c.phase, "flyingOut");
  await w.land();
  assert.equal(w.c.phase, "retracting");
  await w.tick(RETRACT_DELAY_MS);
  assert.deepEqual(w.flying, ["home"]);
});

test("dropped on the desktop from the island: lands with a pop", () => {
  const w = world();
  w.c.installed();
  assert.equal(w.c.phase, "onDesktop");
  assert.equal(w.c.enabled, true);
  assert.equal(w.away, true);
  assert.ok(w.log.includes("sound:pop"));
  assert.ok(w.log.includes("emote:happy"));
});

test("dropped on the desktop while an alert is up: turns right back", () => {
  const w = world({ alert: true });
  w.c.installed();
  assert.equal(w.c.phase, "retracting");
});

test("double click or dropped on the island: home for good", async () => {
  const w = world();
  w.c.installed();
  void w.c.flyHome();
  assert.equal(w.c.phase, "home");
  assert.equal(w.c.enabled, false);
  assert.ok(w.log.includes("home-forget"));
  await w.land();
  assert.equal(w.away, false);
  assert.ok(w.log.includes("sound:peek"));

  // An alert now leaves him in the island.
  w.alert = true;
  w.c.updateAlert(true);
  assert.equal(w.c.phase, "home");
});

test("sent home in the instant before an alert takes him: home wins", async () => {
  const w = world();
  w.c.installed();
  w.alert = true;
  w.c.updateAlert(true);
  assert.equal(w.c.phase, "retracting");
  void w.c.flyHome();
  assert.equal(w.c.phase, "home");
  await w.land();
  await w.tick(RETRACT_DELAY_MS);
  assert.deepEqual(w.flying, [], "the retract has nothing left to do");
  w.alert = false;
  w.c.updateAlert(false);
  await w.tick(RETURN_DELAY_MS);
  assert.deepEqual(w.flying, [], "and he doesn't come back out");
});

// ── The desktop shortcut (flyOutOrHome, ⌃⌥D on the Mac) ───────────────────────

test("the desktop shortcut: out from the island, home from the desktop", async () => {
  const w = world();
  void w.c.flyOutOrHome();
  assert.equal(w.c.enabled, true, "he lives on the desktop now");
  assert.equal(w.c.phase, "flyingOut");
  assert.ok(w.log.includes("out-anywhere"), "a spot on a display that is gone gives way to the corner");
  // Pressed again mid-flight: nothing.
  void w.c.flyOutOrHome();
  assert.deepEqual(w.flying, ["out"]);
  await w.land();
  assert.equal(w.c.phase, "onDesktop");

  void w.c.flyOutOrHome();
  assert.equal(w.c.phase, "home");
  assert.equal(w.c.enabled, false);
  assert.ok(w.log.includes("home-forget"), "home for good, like a double click");
  await w.land();
  assert.equal(w.away, false);
});

test("the desktop shortcut during an alert: he waits in the island, then goes", async () => {
  const w = world({ alert: true });
  w.c.updateAlert(true);
  await w.c.flyOutOrHome();
  assert.equal(w.c.phase, "atNotchForAlert");
  assert.deepEqual(w.flying, []);
  // Away for the alert: the shortcut leaves him be.
  await w.c.flyOutOrHome();
  assert.equal(w.c.phase, "atNotchForAlert");
  w.alert = false;
  w.c.updateAlert(false);
  await w.tick(RETURN_DELAY_MS);
  assert.deepEqual(w.flying, ["out"]);
});

test("the launch keeps him home when his spot's display is gone", async () => {
  const w = world();
  w.c.enabled = true;
  void w.c.launchFlyIfNeeded();
  assert.deepEqual(w.log, ["out-spot"]);
});

test("a finished task gets a happy jump, only on the desktop", () => {
  const w = world();
  w.c.updateState("working");
  w.c.updateState("finished");
  assert.ok(!w.log.includes("emote:happy"), "home: the island's Mochi celebrates");
  w.c.installed();
  w.log.length = 0;
  w.c.updateState("working");
  w.c.updateState("finished");
  w.c.updateState("finished");
  assert.deepEqual(w.log, ["emote:happy"]);
});

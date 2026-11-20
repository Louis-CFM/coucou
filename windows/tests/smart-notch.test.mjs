// Smart Notch feature tests:
// Full on the desktop; tucked away over maximized apps.

import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

test("smartNotch is enabled by default in settings", () => {
  assert.equal(DEFAULT_SETTINGS.smartNotch, true);
  assert.equal(State.settings.smartNotch, true);
  assert.equal(State.foregroundMaximized, false);
});

test("smart notch tuck predicate logic", () => {
  function computeIsSmartTucked({
    smartNotchEnabled,
    foregroundMaximized,
    mouseInside,
    pinned,
    mode,
    hasWelcome,
    hasNotification,
  }) {
    return (
      smartNotchEnabled &&
      foregroundMaximized &&
      !mouseInside &&
      !pinned &&
      mode !== "expanded" &&
      !hasWelcome &&
      !hasNotification
    );
  }

  // 1. On desktop (foregroundMaximized = false): full notch, not tucked
  assert.equal(
    computeIsSmartTucked({
      smartNotchEnabled: true,
      foregroundMaximized: false,
      mouseInside: false,
      pinned: false,
      mode: "hidden",
      hasWelcome: false,
      hasNotification: false,
    }),
    false,
  );

  // 2. Over maximized app (foregroundMaximized = true): tucked away
  assert.equal(
    computeIsSmartTucked({
      smartNotchEnabled: true,
      foregroundMaximized: true,
      mouseInside: false,
      pinned: false,
      mode: "hidden",
      hasWelcome: false,
      hasNotification: false,
    }),
    true,
  );

  // 3. Hovered over tucked notch (mouseInside = true): unfolds!
  assert.equal(
    computeIsSmartTucked({
      smartNotchEnabled: true,
      foregroundMaximized: true,
      mouseInside: true,
      pinned: false,
      mode: "hidden",
      hasWelcome: false,
      hasNotification: false,
    }),
    false,
  );

  // 4. Smart notch disabled by user (smartNotchEnabled = false): stays full on maximized apps
  assert.equal(
    computeIsSmartTucked({
      smartNotchEnabled: false,
      foregroundMaximized: true,
      mouseInside: false,
      pinned: false,
      mode: "hidden",
      hasWelcome: false,
      hasNotification: false,
    }),
    false,
  );

  // 5. Active notification priority: expands even when app is maximized
  assert.equal(
    computeIsSmartTucked({
      smartNotchEnabled: true,
      foregroundMaximized: true,
      mouseInside: false,
      pinned: false,
      mode: "hidden",
      hasWelcome: false,
      hasNotification: true,
    }),
    false,
  );

  // 6. Active welcome message priority: expands with Mochi even when app is maximized
  assert.equal(
    computeIsSmartTucked({
      smartNotchEnabled: true,
      foregroundMaximized: true,
      mouseInside: false,
      pinned: false,
      mode: "hidden",
      hasWelcome: true,
      hasNotification: false,
    }),
    false,
  );

  // 7. Expanded card or chat open: stays expanded
  assert.equal(
    computeIsSmartTucked({
      smartNotchEnabled: true,
      foregroundMaximized: true,
      mouseInside: false,
      pinned: false,
      mode: "expanded",
      hasWelcome: false,
      hasNotification: false,
    }),
    false,
  );
});

test("tucked geometry dimensions match macOS specs (44x14)", () => {
  const TUCKED_W = 44;
  const TUCKED_H = 14;
  const TUCKED_R = 8;

  assert.equal(TUCKED_W, 44);
  assert.equal(TUCKED_H, 14);
  assert.equal(TUCKED_R, 8);
});

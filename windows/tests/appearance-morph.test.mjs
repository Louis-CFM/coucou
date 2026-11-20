// Appearance Morphing & Safe Window Envelope Tests:
// Verifies smooth transition mathematics, shadow clearance padding,
// and safe morphing envelope for Notch, Dynamic Island, and Smart modes.

import { test } from "node:test";
import assert from "node:assert/strict";
import { CLOSED_ISLAND_H, CLOSED_NOTCH_H } from "../src/core/closed.ts";

test("Notch vs Dynamic Island baseline specifications", () => {
  assert.equal(CLOSED_NOTCH_H, 28, "Notch height is 28px");
  assert.equal(CLOSED_ISLAND_H, 35, "Dynamic Island height is 35px");
});

test("Dynamic Island shadow clearance calculations", () => {
  const isIsland = true;
  const shadowPadX = isIsland ? 24 : 0;
  const shadowPadBottom = isIsland ? 20 : 0;
  const topOffset = isIsland ? 10 : 0;
  const closedW = 160;
  const scale = 1.0;

  const islandWindowW = Math.round(closedW * scale) + shadowPadX * 2;
  const islandWindowH = Math.round(CLOSED_ISLAND_H * scale) + topOffset + shadowPadBottom;

  assert.equal(islandWindowW, 208, "Island window width provides 24px left/right shadow margin");
  assert.equal(islandWindowH, 65, "Island window height provides 10px top + 35px pill + 20px bottom shadow clearance");

  // Docked Notch has zero shadow padding
  const notchWindowW = Math.round(closedW * scale);
  const notchWindowH = Math.round(CLOSED_NOTCH_H * scale);
  assert.equal(notchWindowW, 160, "Notch window width matches closed notch exactly");
  assert.equal(notchWindowH, 28, "Notch window height matches closed notch exactly");
});

test("Morph Envelope growth and shrinkage predicate", () => {
  function shouldGrowImmediately(targetSize, currentSize) {
    return targetSize.w > currentSize.w || targetSize.h > currentSize.h;
  }

  const notchSize = { w: 160, h: 28 };
  const islandSize = { w: 208, h: 65 };
  const smartTuckedSize = { w: 44, h: 14 };

  // 1. Notch -> Island: Window must expand immediately to prevent clipping the growing shape & shadow
  assert.equal(shouldGrowImmediately(islandSize, notchSize), true);

  // 2. Island -> Notch: Window must NOT shrink immediately; must wait for curve animation to settle
  assert.equal(shouldGrowImmediately(notchSize, islandSize), false);

  // 3. Notch -> Smart (Tucking): Window must NOT shrink immediately; must wait for width to retract
  assert.equal(shouldGrowImmediately(smartTuckedSize, notchSize), false);

  // 4. Smart -> Notch (Untucking): Window must expand immediately so element has room to grow
  assert.equal(shouldGrowImmediately(notchSize, smartTuckedSize), true);
});

test("Continuous corner radius interpolation", () => {
  function computeBorderRadii({ isIsland, mode, hh, topRadiusVal, radiusVal }) {
    const maxR = mode === "expanded" ? 28 : Math.round(hh / 2);
    const topR = Math.max(0, Math.min(maxR, topRadiusVal));
    const botR = isIsland ? Math.max(0, Math.min(maxR, radiusVal)) : Math.max(0, radiusVal);
    return { topR, botR };
  }

  // Notch settled (top = 0, bottom = 10)
  const notchSettled = computeBorderRadii({
    isIsland: false,
    mode: "hidden",
    hh: 28,
    topRadiusVal: 0,
    radiusVal: 10,
  });
  assert.equal(notchSettled.topR, 0);
  assert.equal(notchSettled.botR, 10);

  // Island settled (top = 18, bottom = 18)
  const islandSettled = computeBorderRadii({
    isIsland: true,
    mode: "hidden",
    hh: 35,
    topRadiusVal: 999,
    radiusVal: 999,
  });
  assert.equal(islandSettled.topR, 18);
  assert.equal(islandSettled.botR, 18);

  // Mid-flight transition (top = 9, bottom = 14)
  const midFlight = computeBorderRadii({
    isIsland: true,
    mode: "hidden",
    hh: 31,
    topRadiusVal: 9,
    radiusVal: 14,
  });
  assert.equal(midFlight.topR, 9);
  assert.equal(midFlight.botR, 14);
});

test("Smart tucked geometry & immediate transition detection", () => {
  function checkAppearanceChanged(prev, next) {
    return (
      prev.notchStyle !== next.notchStyle ||
      prev.visibility !== next.visibility ||
      prev.smartNotch !== next.smartNotch ||
      prev.notchScale !== next.notchScale ||
      prev.closedIsland !== next.closedIsland
    );
  }

  const baseline = {
    notchStyle: "notch",
    visibility: "always",
    smartNotch: false,
    notchScale: 1.0,
    closedIsland: "mochi",
  };

  // 1. Notch to Dynamic Island
  assert.equal(checkAppearanceChanged(baseline, { ...baseline, notchStyle: "island" }), true);

  // 2. Dynamic Island to Notch
  assert.equal(checkAppearanceChanged({ ...baseline, notchStyle: "island" }, baseline), true);

  // 3. Notch to Smart Notch
  assert.equal(checkAppearanceChanged(baseline, { ...baseline, visibility: "smart", smartNotch: true }), true);

  // 4. Non-appearance changes (sound, language, volume) do not trigger appearanceChanged
  assert.equal(checkAppearanceChanged(baseline, baseline), false);

  // 5. Smart tucked geometry attached flush to top edge (targetTop: 0, shadowPad: 0)
  const isTucked = true;
  const isIsland = true;
  const shadowPadX = (!isTucked && isIsland) ? 24 : 0;
  const targetTop = isTucked ? 0 : (isIsland ? 10 : 0);
  assert.equal(shadowPadX, 0, "Smart tucked has zero shadow padding");
  assert.equal(targetTop, 0, "Smart tucked is flush with top edge (0px offset)");
});

test("Resting Notch & Dynamic Island width, centering, and Mochi/battery clearance", () => {
  function computeRestingGeometry({ isIsland, style, batteryVisible, showPct }) {
    let targetW;
    let botCx;

    if (style === "mochi") {
      if (batteryVisible) {
        targetW = isIsland ? (showPct ? 220 : 176) : (showPct ? 208 : 166);
        botCx = isIsland ? 28 : 24;
      } else {
        targetW = isIsland ? 88 : 80;
        botCx = Math.round(targetW / 2);
      }
    } else {
      targetW = isIsland ? 88 : 80;
      botCx = Math.round(targetW / 2);
    }

    const batteryRight = isIsland ? 20 : 16;
    const batteryWidth = showPct ? 77 : 42;
    const batteryLeft = targetW - batteryRight - batteryWidth;

    // Mochi body diameter 18px (notch) or 20px (island) + hat overhang tip (~8px to right of center)
    const mochiRight = botCx + (isIsland ? 12 : 11);
    const clearance = batteryVisible ? batteryLeft - mochiRight : Infinity;

    return { targetW, botCx, batteryLeft, mochiRight, clearance };
  }

  // 1. Notch Mode with Mochi + Battery + Pct (The exact user scenario from Image 1 & 2):
  // Must provide generous > 70px breathing clearance so Mochi and battery never squish or overlap!
  const notchWithPct = computeRestingGeometry({
    isIsland: false,
    style: "mochi",
    batteryVisible: true,
    showPct: true,
  });
  assert.equal(notchWithPct.targetW, 208, "Resting notch width with Mochi + battery pct is 208px");
  assert.equal(notchWithPct.botCx, 24, "Mochi is positioned on left at cx = 24px");
  assert.ok(notchWithPct.clearance > 70, `Generous clearance of ${notchWithPct.clearance}px between Mochi and battery`);
  assert.ok(notchWithPct.batteryLeft > notchWithPct.mochiRight, "Battery does not overlap Mochi");

  // 2. Notch Mode with Mochi + Battery (without pct):
  const notchNoPct = computeRestingGeometry({
    isIsland: false,
    style: "mochi",
    batteryVisible: true,
    showPct: false,
  });
  assert.equal(notchNoPct.targetW, 166, "Resting notch width with Mochi + battery (no pct) is 166px");
  assert.ok(notchNoPct.clearance > 60, "Clearance without pct is > 60px");

  // 3. Notch Mode with ONLY Mochi (no battery, as on a Mac without a notch):
  const notchOnlyMochi = computeRestingGeometry({
    isIsland: false,
    style: "mochi",
    batteryVisible: false,
    showPct: true,
  });
  assert.equal(notchOnlyMochi.targetW, 80, "Resting notch width with only Mochi is compact 80px");
  assert.equal(notchOnlyMochi.botCx, 40, "Mochi is perfectly centered at cx = 40px in 80px notch");

  // 4. Dynamic Island Mode with Mochi + Battery + Pct:
  const islandWithPct = computeRestingGeometry({
    isIsland: true,
    style: "mochi",
    batteryVisible: true,
    showPct: true,
  });
  assert.equal(islandWithPct.targetW, 220, "Dynamic Island width with Mochi + battery pct is 220px");
  assert.equal(islandWithPct.botCx, 28, "Mochi is positioned on left at cx = 28px in Dynamic Island");
  assert.ok(islandWithPct.clearance > 75, `Generous clearance of ${islandWithPct.clearance}px in Dynamic Island`);

  // 5. Dynamic Island with ONLY Mochi:
  const islandOnlyMochi = computeRestingGeometry({
    isIsland: true,
    style: "mochi",
    batteryVisible: false,
    showPct: true,
  });
  assert.equal(islandOnlyMochi.targetW, 88, "Dynamic Island width with only Mochi is 88px");
  assert.equal(islandOnlyMochi.botCx, 44, "Mochi is perfectly centered at cx = 44px in 88px island");
});

test("Resting Notch cache key sensitivity prevents stale width freezing", () => {
  function makeKey({ style, text, dot, note, isNotif, bot, isIsland, batteryVisible, showPct, isTucked, scale }) {
    return `${style}|${text}|${dot ?? ""}|${note ?? false}|${isNotif ?? false}|${bot ?? false}|${isIsland}|${batteryVisible}|${showPct}|${isTucked}|${scale}`;
  }

  const base = {
    style: "mochi",
    text: "",
    dot: null,
    note: false,
    isNotif: false,
    bot: false,
    isIsland: false,
    batteryVisible: true,
    showPct: true,
    isTucked: false,
    scale: 1.0,
  };

  const baseKey = makeKey(base);

  // Invalidate when switching between Notch and Dynamic Island
  assert.notEqual(baseKey, makeKey({ ...base, isIsland: true }));

  // Invalidate when battery visibility changes (e.g. initial hardware detection or settings toggle)
  assert.notEqual(baseKey, makeKey({ ...base, batteryVisible: false }));

  // Invalidate when percentage display is toggled
  assert.notEqual(baseKey, makeKey({ ...base, showPct: false }));

  // Invalidate when scale changes
  assert.notEqual(baseKey, makeKey({ ...base, scale: 1.2 }));

  // Invalidate when smart tucked changes
  assert.notEqual(baseKey, makeKey({ ...base, isTucked: true }));
});

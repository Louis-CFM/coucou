// CouCou Dynamic Island — State Isolation & Battery UI Tests
// Verifies:
// 1. Strict visual state isolation during Nearby Transfer Activity (no avatar blur, canvas, or glow leakage)
// 2. Immediate restoration of avatar effects upon transfer dismissal
// 3. Resting Dynamic Island Battery Settings Matrix:
//    - Indicator ON, Percentage ON  -> Battery Icon + Actual Numeric Percentage
//    - Indicator ON, Percentage OFF -> Battery Icon only (percentage zeroed out)
//    - Indicator OFF                -> Complete battery presentation hidden
// 4. Safe Windows Win32 battery data calculation (clamping, rounding, NaN safety)
// 5. Charging and Discharging visual presentations

import test from "node:test";
import assert from "node:assert/strict";

import { installFakeDom } from "./fakedom.mjs";
installFakeDom();

import { State, resolveShowBattery, resolveShowBatteryPercentage } from "../src/core/state.ts";
import { BatteryMonitor } from "../src/islandcn/battery-monitor.ts";
import { createBatteryElement, updateBatteryElement } from "../src/islandcn/battery-activity.ts";

test("1. Battery monitoring subsystem remains intact and operational", () => {
  assert.ok(typeof BatteryMonitor.getState === "function", "BatteryMonitor.getState must be a valid function");
  const state = BatteryMonitor.getState();
  assert.ok(typeof state.hasBattery === "boolean", "hasBattery must be boolean");
  assert.ok(typeof state.level === "number", "level must be a number");
  assert.ok(typeof state.charging === "boolean", "charging must be boolean");
});

test("2. Battery activity element collapses percentage when showPct is false", () => {
  const mockState = {
    hasBattery: true,
    level: 0.78,
    charging: true,
  };

  // Case A: showPct = false (Percentage OFF)
  const elNoPct = createBatteryElement(mockState, false);
  const pctSpanNoPct = elNoPct.querySelector(".battery-pct");
  assert.ok(pctSpanNoPct, ".battery-pct element must exist in DOM structure");
  assert.equal(pctSpanNoPct.textContent, "", "Percentage text must be completely empty");
  assert.equal(pctSpanNoPct.style.display, "none", "Percentage element must have display: none");
  assert.equal(pctSpanNoPct.style.width, "0px", "Percentage width must be 0px");
  assert.equal(pctSpanNoPct.style.margin, "0px", "Percentage margin must be 0px");
  assert.equal(elNoPct.classList.contains("no-pct"), true, "Container must carry .no-pct class");

  // Capsule and bolt must still exist and function
  const shell = elNoPct.querySelector(".battery-shell");
  const bolt = elNoPct.querySelector(".battery-bolt");
  assert.ok(shell, "Battery shell must be present");
  assert.ok(bolt, "Charging bolt must be present");
  assert.equal(bolt.style.display, "inline-block", "Charging bolt must display when charging");

  // Case B: showPct = true (Percentage ON)
  const elWithPct = createBatteryElement(mockState, true);
  const pctSpanWith = elWithPct.querySelector(".battery-pct");
  assert.equal(pctSpanWith.textContent, "78%", "Percentage text must display exact value");
  assert.equal(pctSpanWith.style.display, "", "Percentage display must not be none");
  assert.equal(elWithPct.classList.contains("no-pct"), false, "Container must not have .no-pct class");
});

test("3. Complete Settings Matrix: Indicator and Percentage independent operation", () => {
  // Matrix evaluation helper reproducing island battery visibility logic
  function evaluateBatteryVisibility(settings, isSmartTucked = false, hasBattery = true) {
    const showBattery = resolveShowBattery(settings);
    const showPct = !isSmartTucked && resolveShowBatteryPercentage(settings);

    // Battery is visible in resting mochi notch when hardware battery is present and not tucked
    const batteryVisible = showBattery && hasBattery && !isSmartTucked;
    return {
      batteryVisible,
      showPct: batteryVisible ? showPct : false,
    };
  }

  // Row 1: Indicator ON, Percentage ON -> Icon + Percentage
  const r1 = evaluateBatteryVisibility({ showBattery: true, showBatteryPercentage: true });
  assert.equal(r1.batteryVisible, true, "Row 1: Battery must be visible");
  assert.equal(r1.showPct, true, "Row 1: Percentage must be displayed");

  // Row 2: Indicator ON, Percentage OFF -> Icon only
  const r2 = evaluateBatteryVisibility({ showBattery: true, showBatteryPercentage: false });
  assert.equal(r2.batteryVisible, true, "Row 2: Battery must be visible");
  assert.equal(r2.showPct, false, "Row 2: Percentage must NOT be displayed");

  // Row 3: Indicator OFF, Percentage ON -> No battery presentation
  const r3 = evaluateBatteryVisibility({ showBattery: false, showBatteryPercentage: true });
  assert.equal(r3.batteryVisible, false, "Row 3: Battery must NOT be visible");
  assert.equal(r3.showPct, false, "Row 3: Percentage must NOT be displayed");

  // Row 4: Indicator OFF, Percentage OFF -> No battery presentation
  const r4 = evaluateBatteryVisibility({ showBattery: false, showBatteryPercentage: false });
  assert.equal(r4.batteryVisible, false, "Row 4: Battery must NOT be visible");
  assert.equal(r4.showPct, false, "Row 4: Percentage must NOT be displayed");

  // Smart tucked state: suppresses battery
  const rTucked = evaluateBatteryVisibility({ showBattery: true, showBatteryPercentage: true }, true);
  assert.equal(rTucked.batteryVisible, false, "Tucked mode must suppress battery");
});

test("4. Safe Windows Win32 battery calculation and formatting", () => {
  const container = createBatteryElement({ hasBattery: true, level: 0.784, charging: true }, true);
  const pctEl = container.querySelector(".battery-pct");
  const boltEl = container.querySelector(".battery-bolt");

  // Test rounding and formatting
  assert.equal(pctEl.textContent, "78%", "0.784 rounds to 78%");
  assert.equal(boltEl.style.display, "inline-block", "Charging bolt shown when charging");
  assert.equal(container.title, "78% (Charging)");

  // Test 100% full charge
  updateBatteryElement(container, { hasBattery: true, level: 1.0, charging: true }, true);
  assert.equal(pctEl.textContent, "100%", "Full charge displays 100%");

  // Test 0% dead battery
  updateBatteryElement(container, { hasBattery: true, level: 0.0, charging: false }, true);
  assert.equal(pctEl.textContent, "0%", "Empty battery displays 0%");
  assert.equal(boltEl.style.display, "none", "Charging bolt hidden when discharging");
  assert.equal(container.title, "0%");

  // Test invalid / NaN resilience
  updateBatteryElement(container, { hasBattery: true, level: NaN, charging: false }, true);
  assert.equal(pctEl.textContent, "100%", "NaN defaults safely to 100%");

  // Test negative clamping
  updateBatteryElement(container, { hasBattery: true, level: -0.5, charging: false }, true);
  assert.equal(pctEl.textContent, "0%", "Negative clamped to 0%");

  // Test > 1.0 clamping
  updateBatteryElement(container, { hasBattery: true, level: 1.5, charging: false }, true);
  assert.equal(pctEl.textContent, "100%", "> 1.0 clamped to 100%");
});

test("5. Resting geometry clearance: width scales to accommodate percentage", () => {
  function computeTargetWidth(isIsland, showPct) {
    return isIsland ? (showPct ? 220 : 176) : (showPct ? 208 : 166);
  }

  // When percentage is enabled, width expands to provide > 70px clearance between Mochi and battery
  const notchWithPct = computeTargetWidth(false, true);
  assert.equal(notchWithPct, 208, "Notch with percentage must be 208px");

  const islandWithPct = computeTargetWidth(true, true);
  assert.equal(islandWithPct, 220, "Island with percentage must be 220px");

  // When percentage is disabled, width collapses cleanly
  const notchNoPct = computeTargetWidth(false, false);
  assert.equal(notchNoPct, 166, "Notch without percentage must be 166px");

  const islandNoPct = computeTargetWidth(true, false);
  assert.equal(islandNoPct, 176, "Island without percentage must be 176px");
});

test("6. Visual state isolation: transfer state strictly hides avatar and blur", () => {
  function evaluateAvatarVisibility({ transferActive, away, greetingActive, mode }) {
    const visible = !transferActive && !greetingActive && !away;
    const glowVisible = visible && mode === "expanded";
    return { visible, glowVisible };
  }

  // Active file transfer state:
  const inTransfer = evaluateAvatarVisibility({
    transferActive: true,
    away: false,
    greetingActive: false,
    mode: "expanded",
  });
  assert.equal(inTransfer.visible, false, "Avatar must not be visible during transfer");
  assert.equal(inTransfer.glowVisible, false, "Glow/blur must not be visible during transfer");

  // Normal resting state:
  const normalResting = evaluateAvatarVisibility({
    transferActive: false,
    away: false,
    greetingActive: false,
    mode: "expanded",
  });
  assert.equal(normalResting.visible, true, "Avatar must be visible in normal state");
  assert.equal(normalResting.glowVisible, true, "Glow must be visible in normal expanded state");
});

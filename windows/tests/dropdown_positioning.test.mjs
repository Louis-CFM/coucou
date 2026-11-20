import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { calculateDropdownPlacement } from "../src/views/dropdown";

describe("Dropdown Positioning Engine & Viewport Boundary Protection", () => {
  it("Scenario 1: Desk sort menu near top of Island (Screenshot defect reproduction)", () => {
    // Exact geometry from the user screenshot in CouCou Dynamic Island:
    // Window is 720x320. The "Recent v" toolbar button is at top: 54, bottom: 82.
    // The sort menu with 10 items (7 sort modes + 3 separators) is 255px tall.
    const anchor = { top: 54, bottom: 82, left: 295, right: 360, width: 65, height: 28 };
    const panelWidth = 160;
    const panelHeight = 255;
    const viewportWidth = 720;
    const viewportHeight = 320;

    const result = calculateDropdownPlacement(
      anchor,
      panelWidth,
      panelHeight,
      viewportWidth,
      viewportHeight,
      { padding: 8, offset: 6 }
    );

    // CRITICAL: MUST NOT flip upward into negative coordinates!
    assert.equal(result.isFlipped, false, "Menu must open downward because spaceBelow (224px) > spaceAbove (40px)");
    assert.ok(result.top >= 8, `Top coordinate (${result.top}) must never be negative or less than padding`);
    assert.equal(result.top, 88, "Top must be anchor.bottom + offset (82 + 6 = 88px)");
    assert.ok(result.maxHeight <= 224, "Height must be constrained to available space (320 - 88 - 8 = 224px)");
    assert.ok(result.top + result.maxHeight <= viewportHeight - 8, "Bottom of menu must not escape viewport boundary");
    assert.equal(result.transformOrigin, "top left");
  });

  it("Scenario 2: Trigger near bottom of viewport flips upward safely", () => {
    // Trigger is near the bottom of a 320px window
    const anchor = { top: 260, bottom: 288, left: 300, right: 360, width: 60, height: 28 };
    const panelWidth = 160;
    const panelHeight = 255;
    const viewportWidth = 720;
    const viewportHeight = 320;

    const result = calculateDropdownPlacement(
      anchor,
      panelWidth,
      panelHeight,
      viewportWidth,
      viewportHeight,
      { padding: 8, offset: 6 }
    );

    assert.equal(result.isFlipped, true, "Menu must flip upward because spaceAbove (246px) > spaceBelow (18px)");
    assert.ok(result.top >= 8, `Top coordinate (${result.top}) must stay within top padding`);
    assert.ok(result.top + result.maxHeight <= anchor.top - 6, "Must not overlap trigger");
    assert.equal(result.transformOrigin, "bottom left");
  });

  it("Scenario 3: Standard window with ample vertical space opens downward without scrolling", () => {
    // Standard settings window: 800x600
    const anchor = { top: 120, bottom: 152, left: 200, right: 350, width: 150, height: 32 };
    const panelWidth = 180;
    const panelHeight = 150;
    const viewportWidth = 800;
    const viewportHeight = 600;

    const result = calculateDropdownPlacement(
      anchor,
      panelWidth,
      panelHeight,
      viewportWidth,
      viewportHeight,
      { padding: 8, offset: 6 }
    );

    assert.equal(result.isFlipped, false);
    assert.equal(result.top, 158); // 152 + 6
    assert.equal(result.maxHeight, 150, "Full height preserved when ample space exists");
    assert.equal(result.transformOrigin, "top left");
  });

  it("Scenario 4: Trigger near right edge of screen aligns right edge to anchor", () => {
    // Trigger is at left 600, right 690 in a 720px wide window
    const anchor = { top: 100, bottom: 132, left: 600, right: 690, width: 90, height: 32 };
    const panelWidth = 200;
    const panelHeight = 120;
    const viewportWidth = 720;
    const viewportHeight = 500;

    const result = calculateDropdownPlacement(
      anchor,
      panelWidth,
      panelHeight,
      viewportWidth,
      viewportHeight,
      { padding: 8, offset: 6 }
    );

    assert.equal(result.isRightAligned, true, "Must align right edge to anchor to prevent right boundary overflow");
    assert.equal(result.left, 490, "Left must be anchor.right - panelWidth (690 - 200 = 490)");
    assert.ok(result.left + panelWidth <= viewportWidth - 8, "Must not overflow right viewport edge");
    assert.equal(result.transformOrigin, "top right");
  });

  it("Scenario 5: Trigger near left edge of screen respects left padding", () => {
    const anchor = { top: 100, bottom: 132, left: 2, right: 50, width: 48, height: 32 };
    const panelWidth = 150;
    const panelHeight = 100;
    const viewportWidth = 720;
    const viewportHeight = 500;

    const result = calculateDropdownPlacement(
      anchor,
      panelWidth,
      panelHeight,
      viewportWidth,
      viewportHeight,
      { padding: 8, offset: 6 }
    );

    assert.ok(result.left >= 8, `Left (${result.left}) must be clamped to minimum padding of 8px`);
    assert.equal(result.isRightAligned, false);
    assert.equal(result.transformOrigin, "top left");
  });

  it("Scenario 6: Very short viewport picks greater space and clamps height with zero clipping", () => {
    // Extremely constrained viewport: 180px height
    const anchor = { top: 70, bottom: 100, left: 100, right: 200, width: 100, height: 30 };
    const panelWidth = 150;
    const panelHeight = 220; // taller than entire viewport!
    const viewportWidth = 600;
    const viewportHeight = 180;

    const result = calculateDropdownPlacement(
      anchor,
      panelWidth,
      panelHeight,
      viewportWidth,
      viewportHeight,
      { padding: 8, offset: 6 }
    );

    // spaceBelow = 180 - 100 - 6 - 8 = 66
    // spaceAbove = 70 - 6 - 8 = 56
    // spaceBelow (66) > spaceAbove (56) -> isFlipped = false
    assert.equal(result.isFlipped, false);
    assert.ok(result.top >= 8);
    assert.ok(result.top + result.maxHeight <= viewportHeight - 8);
  });

  it("Scenario 7: Combined upward flip with right alignment produces 'bottom right' origin", () => {
    const anchor = { top: 250, bottom: 280, left: 550, right: 690, width: 140, height: 30 };
    const panelWidth = 220;
    const panelHeight = 200;
    const viewportWidth = 700;
    const viewportHeight = 300;

    const result = calculateDropdownPlacement(
      anchor,
      panelWidth,
      panelHeight,
      viewportWidth,
      viewportHeight,
      { padding: 8, offset: 6 }
    );

    assert.equal(result.isFlipped, true);
    assert.equal(result.isRightAligned, true);
    assert.equal(result.transformOrigin, "bottom right");
  });
});

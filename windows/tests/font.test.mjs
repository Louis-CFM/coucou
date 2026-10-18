// The font and text size of the user's own (src/core/font.ts): what a stored
// preference is allowed to put in the stylesheet, and that the defaults leave
// the page exactly as shipped.

import { test } from "node:test";
import assert from "node:assert/strict";

const { applyFont, cleanFontFamily, cleanFontScale, fontStack, FONT_SCALE_MAX, FONT_SCALE_MIN } =
  await import("../src/core/font.ts");

/** A stand-in for <html>: records the custom properties set on it. */
function fakeRoot() {
  const props = new Map();
  return {
    props,
    style: {
      setProperty: (k, v) => props.set(k, v),
      removeProperty: (k) => props.delete(k),
    },
  };
}

test("a family name loses what could end the CSS declaration", () => {
  assert.equal(cleanFontFamily("Cascadia Code"), "Cascadia Code");
  assert.equal(cleanFontFamily('Evil"; color: red; }'), "Evil color: red");
  assert.equal(cleanFontFamily("  A \n  B\ "), "A B");
  assert.equal(cleanFontFamily("x".repeat(200)).length, 80);
  assert.equal(cleanFontFamily(42), "");
  assert.equal(cleanFontFamily(undefined), "");
});

test("the chosen font goes in front of the default stack", () => {
  const stack = fontStack("Cascadia Code");
  assert.ok(stack.startsWith('"Cascadia Code", system-ui'));
  assert.ok(stack.endsWith("sans-serif"));
  assert.equal(fontStack(""), fontStack("   "));
});

test("the text size is kept inside its range, in steps of 5 %", () => {
  assert.equal(cleanFontScale(1), 1);
  assert.equal(cleanFontScale(0.1), FONT_SCALE_MIN);
  assert.equal(cleanFontScale(9), FONT_SCALE_MAX);
  assert.equal(cleanFontScale(Number.NaN), 1);
  assert.equal(cleanFontScale("big"), 1);
  assert.equal(cleanFontScale(1.12), 1.1);
});

test("the defaults set nothing on the page", () => {
  const root = fakeRoot();
  applyFont({ fontFamily: "", fontScale: 1 }, root);
  assert.equal(root.props.size, 0);
  applyFont({}, root);
  assert.equal(root.props.size, 0);
});

test("a picked font and size are set, and taken off again when reset", () => {
  const root = fakeRoot();
  applyFont({ fontFamily: "Consolas", fontScale: 1.2 }, root);
  assert.ok(root.props.get("--font").startsWith('"Consolas", '));
  assert.equal(root.props.get("--fs"), "1.2");
  applyFont({ fontFamily: "", fontScale: 1 }, root);
  assert.equal(root.props.size, 0);
});

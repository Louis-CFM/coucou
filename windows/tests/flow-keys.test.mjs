// The dictation key: the left keys and a shortcut of one's own (src/hub/keys.ts,
// keyLabel in src/hub/ui.ts, flowKeyId in src/core/flow.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import { comboFromKeys, knownCode } from "../src/hub/keys.ts";
import { keyLabel } from "../src/hub/ui.ts";
import { flowKeyId } from "../src/core/flow.ts";
import { setLanguage } from "../src/i18n/i18n.ts";

test("the keys held become a shortcut: modifiers first, known keys only, four at most", () => {
  assert.deepEqual(comboFromKeys(["KeyF", "ShiftLeft", "AltLeft"]), ["AltLeft", "ShiftLeft", "KeyF"]);
  assert.deepEqual(comboFromKeys(["ControlLeft"]), ["ControlLeft"]);
  assert.deepEqual(comboFromKeys(["Numpad5", "KeyQ"]), ["KeyQ"]);
  assert.deepEqual(comboFromKeys(["ControlLeft", "AltLeft", "ShiftLeft", "MetaLeft", "KeyF"]), ["ControlLeft", "AltLeft", "ShiftLeft", "MetaLeft"]);
  assert.equal(knownCode("F13"), true);
  assert.equal(knownCode("F25"), false);
  assert.equal(knownCode("Enter"), false);
});

test("a key is written the way it is printed", () => {
  setLanguage("en");
  assert.equal(keyLabel("left_alt"), "Left Alt");
  assert.equal(keyLabel("custom:AltLeft+ShiftLeft+KeyF"), "Alt + Shift + F");
  assert.equal(keyLabel("custom:ControlLeft+MetaLeft", "linux"), "Ctrl + Super");
  assert.equal(keyLabel("custom:AltRight"), "Right Alt");
  assert.equal(keyLabel("custom:F9"), "F9");
  assert.equal(keyLabel("custom:"), "Right Ctrl");
  assert.equal(flowKeyId({ key: "custom", keyCombo: ["AltLeft", "KeyF"] }), "custom:AltLeft+KeyF");
  assert.equal(flowKeyId({ key: "left_shift", keyCombo: [] }), "left_shift");
  setLanguage("fr");
  assert.equal(keyLabel("left_ctrl"), "Ctrl de gauche");
});

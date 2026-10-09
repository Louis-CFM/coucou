import { test } from "node:test";
import assert from "node:assert/strict";
import { chatPromptHeight, islandSize, PANEL_H } from "../src/core/layout.ts";
import { readFileSync } from "node:fs";
test("chat opens tall and long conversations grow to 680px", () => {
  assert.equal(chatPromptHeight(0), 480);
  assert.equal(chatPromptHeight(1), 540);
  assert.equal(chatPromptHeight(4), 680);
  assert.equal(chatPromptHeight(1000), 680);
});
test("chat reserves room at the bottom of small high-DPI screens", () => {
  assert.equal(chatPromptHeight(100, 432), 408);
  assert.equal(chatPromptHeight(0, 432), 408);
  assert.equal(chatPromptHeight(100, 300), 276);
  assert.equal(chatPromptHeight(1, 6), 0);
});
test("only the expanded chat grows; compact and other views stay unchanged", () => {
  assert.deepEqual(islandSize("compact", "prompt", 99), {w:288,h:32});
  assert.deepEqual(islandSize("hidden", "prompt", 99), {w:184,h:0});
  assert.deepEqual(islandSize("expanded", "overview", 99), {w:640,h:160});
  assert.deepEqual(islandSize("expanded", "prompt", 99, 432), {w:640,h:408});
});
test("native and frontend panel height agree", () => {
  const native=readFileSync(new URL("../src-tauri/src/island.rs", import.meta.url),"utf8");
  assert.ok(native.includes(`pub const PANEL_H: f64 = ${PANEL_H}.0;`));
  assert.ok(native.includes("PANEL_H.min((ms.height as f64 / scale - 48.0).max(1.0))"));
});

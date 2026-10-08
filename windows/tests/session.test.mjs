// What a Claude Code session runs with: the labels its pill shows, and the order
// the approval card cycles through the permission modes (src/core/session.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  PERMISSION_MODES, effortLevel, isPermissionMode, modeLabel, modeSkipsPrompts, modelLabel, nextMode,
} from "../src/core/session.ts";

test("model ids read as family and version", () => {
  assert.equal(modelLabel("claude-opus-5-5"), "Opus 5.5");
  assert.equal(modelLabel("claude-haiku-4-5-20251001"), "Haiku 4.5");
  assert.equal(modelLabel("claude-fable-5-1"), "Fable 5.1");
  assert.equal(modelLabel("claude-sonnet-5-5[1m]"), "Sonnet 5.5 1M");
  assert.equal(modelLabel("claude-opus-4"), "Opus 4");
  // Anything else is shown as it came.
  assert.equal(modelLabel("Opus"), "Opus");
  assert.equal(modelLabel("gpt-5"), "gpt-5");
  assert.equal(modelLabel(" opusplan "), "opusplan");
});

test("modes read as Claude Code names them, and cycle back round", () => {
  assert.equal(modeLabel("default"), "Manual");
  assert.equal(modeLabel("manual"), "Manual");
  assert.equal(modeLabel("acceptEdits"), "Accept edits");
  assert.equal(modeLabel("somethingNew"), "somethingNew");
  let mode = "default";
  const seen = [];
  for (let i = 0; i < PERMISSION_MODES.length; i++) {
    seen.push(mode);
    mode = nextMode(mode);
  }
  assert.equal(mode, "default");
  assert.deepEqual([...seen].sort(), [...PERMISSION_MODES].sort());
  assert.equal(isPermissionMode("manual"), false);
  assert.ok(modeSkipsPrompts("bypassPermissions") && modeSkipsPrompts("dontAsk"));
  assert.ok(!modeSkipsPrompts("auto"));
});

test("effort is read from its object or as a bare level, and nothing else", () => {
  assert.equal(effortLevel({ level: "xhigh" }), "xhigh");
  assert.equal(effortLevel("low"), "low");
  assert.equal(effortLevel({}), null);
  assert.equal(effortLevel({ level: 3 }), null);
  assert.equal(effortLevel({ level: "<b>x</b>" }), null);
  assert.equal(effortLevel(null), null);
});

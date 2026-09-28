/**
 * Pure unit tests for Codex companion state mapping (no network / no tokens).
 * Run: npx --yes tsx --test src/services/ai/event-adapter.test.ts
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { companionStateFromAgent } from "./event-adapter.js";

describe("companionStateFromAgent", () => {
  it("maps thinking/connecting to thinking", () => {
    assert.equal(companionStateFromAgent("thinking"), "thinking");
    assert.equal(companionStateFromAgent("connecting"), "thinking");
  });

  it("maps file and shell work to working", () => {
    assert.equal(companionStateFromAgent("editing"), "working");
    assert.equal(companionStateFromAgent("writing"), "working");
    assert.equal(companionStateFromAgent("running_command"), "working");
  });

  it("maps search/read to searching", () => {
    assert.equal(companionStateFromAgent("searching"), "searching");
    assert.equal(companionStateFromAgent("reading"), "searching");
  });

  it("maps waiting to approval", () => {
    assert.equal(companionStateFromAgent("waiting_for_user"), "approval");
  });

  it("maps terminal outcomes", () => {
    assert.equal(companionStateFromAgent("success"), "finished");
    assert.equal(companionStateFromAgent("error"), "error");
    assert.equal(companionStateFromAgent("idle"), "idle");
  });
});

// Agents other than Claude Code (src/island/agents.ts): the pill names and
// colours of PillCatalog.swift, and who may get an approval card.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  APPROVAL_AGENTS, KNOWN_AGENTS, agentColor, agentName, validateAgent,
} from "../src/island/agents.ts";

test("known agents carry the Mac's names and colours", () => {
  assert.equal(agentName("gemini"), "Gemini CLI");
  assert.equal(agentColor("gemini"), "#8AB4F8");
  assert.equal(agentName("copilot"), "Copilot CLI");
  assert.equal(agentColor("codex"), "#2DD4BF");
  assert.equal(agentColor("cursor"), "#C0C4CC");
  for (const [id, { color }] of Object.entries(KNOWN_AGENTS)) {
    assert.equal(validateAgent(id), id, id);
    assert.match(color, /^#[0-9A-F]{6}$/, id);
  }
});

test("an unknown agent keeps its id and gets a stable colour", () => {
  assert.equal(agentName("my-tool"), "my-tool");
  assert.equal(agentColor("my-tool"), agentColor("my-tool"));
  assert.match(agentColor("my-tool"), /^#[0-9A-F]{6}$/);
});

test("the agent tag is checked the Mac's way, and claude is reserved", () => {
  for (const bad of ["claude", "Gemini", "has space", "a".repeat(25), "", undefined, "x_y"]) {
    assert.equal(validateAgent(bad), null, String(bad));
  }
  assert.equal(validateAgent("a".repeat(24)), "a".repeat(24));
});

test("approval cards are for the agents the relay answers, no one else", () => {
  // Must match takes_decisions() in hook/src/reply.rs.
  assert.deepEqual([...APPROVAL_AGENTS].sort(), ["codex", "copilot", "muse"]);
});

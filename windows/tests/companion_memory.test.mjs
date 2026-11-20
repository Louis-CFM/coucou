import test from "node:test";
import assert from "node:assert/strict";

import { CompanionMemory } from "../src/companion/memory.ts";

test("CompanionMemory fnv1a generates consistent 32-bit hashes", () => {
  const h1 = CompanionMemory.fnv1a("Welcome back Alex!");
  const h2 = CompanionMemory.fnv1a("welcome back alex!");
  const h3 = CompanionMemory.fnv1a("Completely different string");

  assert.equal(h1, h2, "Should match regardless of casing");
  assert.notEqual(h1, h3, "Different text should produce different hashes");
  assert.ok(typeof h1 === "number" && h1 > 0);
});

test("CompanionMemory detects exact duplicates via FNV-1a fingerprint", () => {
  CompanionMemory.clear();
  const text = "Welcome back, Sarah! Let's get to work ✨";

  assert.equal(CompanionMemory.isDuplicateOrSimilar(text), false);
  CompanionMemory.record(text, "greeting_return", "ollama");

  assert.equal(CompanionMemory.isDuplicateOrSimilar(text), true);
  assert.equal(CompanionMemory.isDuplicateOrSimilar("welcome back, sarah! let's get to work ✨"), true);
});

test("CompanionMemory detects lexical stem similarity via Jaccard index", () => {
  CompanionMemory.clear();
  const original = "Remember to stay hydrated and drink some water today 💧";
  CompanionMemory.record(original, "hydration_reminder", "ollama");

  // Highly similar sentence sharing stems ("stay", "hydrated", "drink", "water")
  const similar = "Please stay hydrated and drink fresh water today 💧";
  assert.equal(CompanionMemory.isDuplicateOrSimilar(similar), true);

  // Unrelated sentence
  const different = "Great job finishing that intense coding marathon! 🚀";
  assert.equal(CompanionMemory.isDuplicateOrSimilar(different), false);
});

test("CompanionMemory enforces 50-entry LRU ring buffer bound", () => {
  CompanionMemory.clear();
  for (let i = 0; i < 60; i++) {
    CompanionMemory.record(`Greeting message number ${i}`, "greeting_return", "ollama");
  }

  assert.equal(CompanionMemory.count, 50, "Memory must be bounded to 50 entries max");
});

test("CompanionMemory tracks recent exclusions for prompt negative sampling", () => {
  CompanionMemory.clear();
  CompanionMemory.record("Msg A", "greeting_return", "ollama");
  CompanionMemory.record("Msg B", "greeting_return", "ollama");
  CompanionMemory.record("Msg C", "greeting_return", "ollama");

  const exclusions = CompanionMemory.getRecentExclusions();
  assert.deepEqual(exclusions, ["Msg C", "Msg B", "Msg A"]);
});

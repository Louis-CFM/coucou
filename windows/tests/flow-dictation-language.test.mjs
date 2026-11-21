import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { DICTATION_LANGUAGES } from "../src/core/flow.ts";

test("DICTATION_LANGUAGES covers the 25 supported Parakeet languages without duplicates", () => {
  assert.equal(DICTATION_LANGUAGES.length, 25);
  const codes = DICTATION_LANGUAGES.map(([code]) => code);
  assert.equal(new Set(codes).size, 25);
  assert.ok(codes.includes("fr"));
  assert.ok(codes.includes("en"));
  assert.ok(codes.includes("tr"));
  assert.ok(!codes.includes(""), "Auto-detect empty code is added separately as Automatic");
});

test("DICTATION_LANGUAGES matches Rust dictation_language_name mappings", () => {
  const rust = readFileSync(join(process.cwd(), "src-tauri/src/flow/store.rs"), "utf8");
  for (const [code] of DICTATION_LANGUAGES) {
    assert.ok(rust.includes(`"${code}" => Some(`), `Missing Rust mapping for ${code}`);
  }
});

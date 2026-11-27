/**
 * brain coverage — compare state elements to a golden set and find gaps.
 *
 * Golden set: a JSON file with expected elements (by texte_contains + expected page).
 * Coverage check: for each golden element, search all state files for a matching element.
 *
 * Priority levels:
 *   "must"   — must always be present; failures block coverage. Fix the prompt, never the test.
 *   "should" — expected but LLM variability is acceptable.
 */
import fs from "node:fs";
import path from "node:path";
import { expandHome } from "./utils.js";
import type { BrainConfig } from "./config.js";
import type { StoredElement } from "./elements.js";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface GoldenElement {
  id: string;             // "auto" (not used for matching)
  priority: "must" | "should";
  kind: string;
  texte_contains: string; // substring to match (case-insensitive)
  expected_in: string[];  // IDs of pages where this element must appear
                          // e.g. ["proj_portfo"], ["lessons"], ["louis"]
}

export interface CoverageResult {
  must_ok: number;
  must_total: number;
  should_ok: number;
  should_total: number;
  missing: Array<{ element: GoldenElement; found_in: string[] }>;
  /** Convenience: true only when all must pass */
  must_pass: boolean;
}

// ── State loading ─────────────────────────────────────────────────────────────

interface AnyState {
  id: string;
  elements: StoredElement[];
}

function loadAllStates(config: BrainConfig): Map<string, StoredElement[]> {
  const base = expandHome(config.brainPath);
  const stateDir = path.join(base, ".state", "proj");
  const result = new Map<string, StoredElement[]>();

  if (!fs.existsSync(stateDir)) return result;

  for (const f of fs.readdirSync(stateDir)) {
    if (!f.endsWith(".json")) continue;
    try {
      const raw = fs.readFileSync(path.join(stateDir, f), "utf8");
      const state = JSON.parse(raw) as AnyState;
      if (state.id && Array.isArray(state.elements)) {
        result.set(state.id, state.elements);
      }
    } catch {
      // Skip unreadable state files
    }
  }

  return result;
}

// ── Coverage check ────────────────────────────────────────────────────────────

/**
 * Check if a golden element exists in the expected pages.
 * Returns the list of pages where a matching element was found.
 */
function findGoldenElement(
  golden: GoldenElement,
  allStates: Map<string, StoredElement[]>
): string[] {
  const needle = golden.texte_contains.toLowerCase();
  const foundIn: string[] = [];

  for (const pageId of golden.expected_in) {
    const elements = allStates.get(pageId) ?? [];
    const found = elements.some(
      (e) =>
        e.kind === golden.kind &&
        e.texte.toLowerCase().includes(needle)
    );
    if (found) foundIn.push(pageId);
  }

  return foundIn;
}

// ── Main coverage function ─────────────────────────────────────────────────────

export function runCoverage(config: BrainConfig, goldenPath: string): CoverageResult {
  if (!fs.existsSync(goldenPath)) {
    throw new Error(`Golden set file not found: ${goldenPath}`);
  }

  const goldenSet: GoldenElement[] = JSON.parse(fs.readFileSync(goldenPath, "utf8"));
  const allStates = loadAllStates(config);

  const missing: CoverageResult["missing"] = [];
  let must_ok = 0;
  let must_total = 0;
  let should_ok = 0;
  let should_total = 0;

  for (const golden of goldenSet) {
    const isMust = golden.priority === "must";
    if (isMust) must_total++; else should_total++;

    const foundIn = findGoldenElement(golden, allStates);
    const allFound = golden.expected_in.every((p) => foundIn.includes(p));

    if (allFound) {
      if (isMust) must_ok++; else should_ok++;
    } else {
      missing.push({ element: golden, found_in: foundIn });
    }
  }

  return {
    must_ok,
    must_total,
    should_ok,
    should_total,
    missing,
    must_pass: must_ok === must_total,
  };
}

// ── Formatting ────────────────────────────────────────────────────────────────

export function formatCoverageResult(result: CoverageResult): string {
  const lines: string[] = [];

  const mustSymbol = result.must_pass ? "✓" : "✗";
  lines.push(`${mustSymbol} must  ${result.must_ok}/${result.must_total}`);

  const shouldSymbol = result.should_ok === result.should_total ? "✓" : "~";
  lines.push(`${shouldSymbol} should ${result.should_ok}/${result.should_total}`);

  const mustMissing = result.missing.filter((m) => m.element.priority === "must");
  const shouldMissing = result.missing.filter((m) => m.element.priority === "should");

  if (mustMissing.length > 0) {
    lines.push("");
    lines.push("MUST — missing:");
    for (const { element, found_in } of mustMissing) {
      const expected = element.expected_in.join(", ");
      const foundStr = found_in.length > 0 ? ` (found in: ${found_in.join(", ")})` : "";
      lines.push(`  ✗ [${element.kind}] "${element.texte_contains}" → expected in [${expected}]${foundStr}`);
    }
  }

  if (shouldMissing.length > 0) {
    lines.push("");
    lines.push("SHOULD — missing:");
    for (const { element, found_in } of shouldMissing) {
      const expected = element.expected_in.join(", ");
      const foundStr = found_in.length > 0 ? ` (found in: ${found_in.join(", ")})` : "";
      lines.push(`  ~ [${element.kind}] "${element.texte_contains}" → expected in [${expected}]${foundStr}`);
    }
  }

  return lines.join("\n");
}

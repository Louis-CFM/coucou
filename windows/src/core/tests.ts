// Test runs an agent made, and what they really said — the island's half of
// dotpals' "Was it tested?" (bridge/ui/story.js testVerdict, MIT, see
// windows/THIRD_PARTY_NOTICES.md). The relay keeps the end of a test command's
// output (coucou-hook, main.rs); its own summary decides (testout.ts), else the
// exit status, unless the output disagrees. What stays unclear can be settled
// by the optional double-check, Laya on this computer or TypeSafe's Jev
// (src-tauri/src/tests_check.rs).

import { parseTestOutput } from "./testout";
import { t } from "../i18n/i18n";

/** A test command, as dotpals tells them apart (story.js TEST). */
export const TEST_COMMAND =
  /\b(npm|pnpm|yarn|bun)\s+(run\s+)?test\b|\bnode\s+--test\b|\b(jest|vitest|mocha|ava|pytest|tox|nox|rspec|phpunit|playwright\s+test|cypress\s+run)\b|\bgo\s+test\b|\bcargo\s+test\b|\bdotnet\s+test\b|\bgradle\w*\s+test\b|\bmvn\w*\s+test\b|\bpython\s+-m\s+(pytest|unittest)\b|\bdeno\s+test\b|\bmake\s+test\b/i;

/** Output that looks broken, or fine, when it has no summary to count from (story.js). */
const BROKE = /\bFAIL(?:ED|URE)?\b|\bfailing\b|^Traceback \(most recent call last\)|\bpanicked\b|\b\w*Error:|^\s*[✕✖×]\s|^not ok\b/m;
const FINE = /^\s*(?:PASS|ok)\s|\ball (?:\d+ )?tests? passed\b|^OK\b|^\s*[✓✔]\s/m;

export interface TestFacts {
  runner: string | null;
  passed: number;
  failed: number;
  errors: number;
  skipped: number;
  total: number;
  failing: string[];
  parsed: boolean;
}

export type TestState = "passed" | "failed" | "unclear";

export interface TestVerdict {
  state: TestState;
  /** How it is known: the output's summary, the exit status, or the double-check. */
  source: "output" | "exit" | "checker";
  facts: TestFacts;
  /** Why it is unclear, for the step and for the checker. */
  reason?: "no-tests" | "stopped" | "piped" | "not-last" | "clean-but-failed" | "errors-but-ok";
}

export interface TestRun {
  command: string;
  /** The end of what it printed, stdout then stderr. */
  output: string;
  /** It exited non-zero (PostToolUseFailure). */
  failed: boolean;
  /** It was interrupted before it finished. */
  stopped: boolean;
}

export function isTestCommand(command: string): boolean {
  return TEST_COMMAND.test(command);
}

/** The tests' output goes through a pipe (`npm test | tail`): the exit code is the last command's. */
function piped(command: string): boolean {
  const i = command.search(TEST_COMMAND);
  return i >= 0 && /\|(?!\|)/.test(command.slice(i));
}

/** Another command runs after the tests whatever they did (`npm test; echo done`). */
function notLast(command: string): boolean {
  const i = command.search(TEST_COMMAND);
  return i >= 0 && /;\s*\S/.test(command.slice(i));
}

/** How a test run ended, and how it is known (story.js testVerdict). */
export function testVerdict(run: TestRun): TestVerdict {
  const facts = parseTestOutput(run.output) as TestFacts;
  if (facts.parsed && facts.failed + facts.errors > 0) return { state: "failed", source: "output", facts };
  if (facts.parsed && facts.passed > 0) return { state: "passed", source: "output", facts };
  // Nothing ran is not a pass.
  if (facts.parsed) return { state: "unclear", source: "output", facts, reason: "no-tests" };
  if (run.stopped) return { state: "unclear", source: "exit", facts, reason: "stopped" };
  if (piped(run.command)) return { state: "unclear", source: "exit", facts, reason: "piped" };
  if (notLast(run.command)) return { state: "unclear", source: "exit", facts, reason: "not-last" };
  if (run.failed) {
    return FINE.test(run.output) && !BROKE.test(run.output)
      ? { state: "unclear", source: "exit", facts, reason: "clean-but-failed" }
      : { state: "failed", source: "exit", facts };
  }
  return BROKE.test(run.output)
    ? { state: "unclear", source: "exit", facts, reason: "errors-but-ok" }
    : { state: "passed", source: "exit", facts };
}

/** Worth asking the double-check about: unclear, and not just "nothing ran" (never a pass). */
export function worthChecking(v: TestVerdict): boolean {
  return v.state === "unclear" && v.reason !== "no-tests";
}

/** "1 failed, 47 passed, 2 skipped". */
export function countWords(f: TestFacts): string {
  const parts: string[] = [];
  if (f.failed) parts.push(t("{n} failed", { n: f.failed }));
  if (f.errors) parts.push(t("{n} errors", { n: f.errors }));
  if (f.passed) parts.push(t("{n} passed", { n: f.passed }));
  if (f.skipped) parts.push(t("{n} skipped", { n: f.skipped }));
  return parts.join(", ") || t("0 tests");
}

/** The failing tests' own names, at most two: "test_locked +1". */
function failingNames(f: TestFacts): string {
  const names = f.failing.map((n) => String(n).split("::").pop()!.split(" › ").pop()!.trim()).filter(Boolean);
  if (!names.length) return "";
  const shown = names.slice(0, 2).map((n) => (n.length > 50 ? `${n.slice(0, 49)}…` : n));
  return `: ${shown.join(", ")}${names.length > 2 ? ` +${names.length - 2}` : ""}`;
}

/** The step the agent's card shows: "Tests passed · 48 passed", "Tests failed · 1 failed: sum". */
export function verdictStep(v: TestVerdict, check?: { by: "laya" | "jev"; p: number } | null): string {
  const by = check ? (check.by === "laya" ? "Laya" : "Jev") : "";
  if (v.source === "checker" && check) {
    const sure = Math.round((v.state === "passed" ? check.p : 1 - check.p) * 100);
    const what = v.state === "passed" ? t("Tests passed") : t("Tests failed");
    return `${what} · ${t("checked by {by}, {sure}% sure", { by, sure })}`;
  }
  if (v.state === "passed") return `${t("Tests passed")} · ${v.source === "output" ? countWords(v.facts) : t("exit code only")}`;
  if (v.state === "failed") {
    return `${t("Tests failed")} · ${v.source === "output" ? countWords(v.facts) + failingNames(v.facts) : t("exit code only")}`;
  }
  const why: Record<NonNullable<TestVerdict["reason"]>, string> = {
    "no-tests": t("no tests actually ran"),
    stopped: t("it didn't finish"),
    piped: t("its output went through a pipe"),
    "not-last": t("another command ran after the tests"),
    "clean-but-failed": t("it failed, but the output looks fine"),
    "errors-but-ok": t("it passed, but the output shows errors"),
  };
  return `${t("Tests unclear")} · ${v.reason ? why[v.reason] : ""}`;
}

/** The double-check's answer: P(the tests pass) → a state (dotpals' thresholds, 0.7 / 0.3). */
export function stateOfProbability(p: number): TestState {
  return p >= 0.7 ? "passed" : p <= 0.3 ? "failed" : "unclear";
}

/** What the double-check is shown about a run: the parsed facts, the exit, the end of the output. */
export function evidenceOf(run: TestRun, v: TestVerdict): Record<string, unknown> {
  const FAILURE_LINE = /\bFAIL(?:ED|URE)?\b|\bfailing\b|Traceback \(most recent call last\)|\bpanicked\b|\b\w*Error:|^\s*[✕✖×]\s|^not ok\b|\bexit (?:code|status)\b/;
  const lines = run.output.split("\n");
  const f = v.facts;
  return {
    command: run.command.slice(0, 300),
    exit_status: run.stopped ? "did not finish" : run.failed ? "failed" : "ok",
    parsed: f.parsed ? { runner: f.runner, passed: f.passed, failed: f.failed, errors: f.errors, skipped: f.skipped, failing: f.failing } : null,
    failure_lines: lines.filter((l) => FAILURE_LINE.test(l)).slice(-12).map((l) => l.trim().slice(0, 200)),
    output_end: run.output.length > 1500 ? `…${run.output.slice(-1500)}` : run.output,
  };
}

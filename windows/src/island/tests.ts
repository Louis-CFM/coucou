// Test runs an agent made → its card. The relay keeps the end of a test
// command's output; its verdict becomes a step ("Tests passed · 48 passed",
// "Tests failed · 1 failed: test_sum"), a failure badges the pill, and an
// unclear run is asked about once when the double-check is on (Laya here, or
// Jev): dotpals' "Was it tested?". The fix loop (./loop.ts) waits for the same
// answer rather than asking twice.

import { Bridge, type CheckAnswer } from "../core/bridge";
import { State } from "../core/state";
import {
  evidenceOf, stateOfProbability, testVerdict, verdictStep, worthChecking, type TestRun, type TestVerdict,
} from "../core/tests";
import { t } from "../i18n/i18n";

interface TestPayload {
  session_id?: string;
  tool_use_id?: string;
  tool_input?: Record<string, unknown>;
  coucou_test_output?: unknown;
  coucou_test_failed?: unknown;
  coucou_test_stopped?: unknown;
}

/** The double-check's answer for a run, by `<session>:<tool_use_id>`: the fix loop reads the same one. */
const checks = new Map<string, Promise<CheckAnswer | null>>();

export function checkFor(key: string): Promise<CheckAnswer | null> | undefined {
  return checks.get(key);
}

/** The step `from` on `pillId`'s card becomes `to` (the double-check answered). */
function replaceStep(pillId: string, from: string, to: string) {
  const task = State.tasks.find((x) => x.id === pillId);
  if (!task) return;
  const i = task.steps.lastIndexOf(from);
  if (i < 0) return;
  task.steps[i] = to;
  State.notify();
}

export function recordTestRun(pillId: string, payload: TestPayload) {
  if (typeof payload.coucou_test_output !== "string") return;
  const run: TestRun = {
    command: String(payload.tool_input?.command ?? ""),
    output: payload.coucou_test_output,
    failed: payload.coucou_test_failed === true,
    stopped: payload.coucou_test_stopped === true,
  };
  const verdict = testVerdict(run);
  const step = verdictStep(verdict);
  State.appendStep(pillId, step);
  if (verdict.state === "failed" && State.focusId !== pillId) State.setPillBadge(pillId, "error");

  if (!worthChecking(verdict) || State.settings.testChecker === "off" || !State.settings.testChecker) return;
  const asked = Bridge.testsCheck(evidenceOf(run, verdict)).catch(() => null);
  if (payload.session_id && payload.tool_use_id) {
    checks.set(`${payload.session_id}:${payload.tool_use_id}`, asked);
    if (checks.size > 50) checks.delete(checks.keys().next().value!);
  }
  void asked.then((answer) => {
    if (!answer) return;
    const by = answer.by === "laya" ? "Laya" : "Jev";
    if (answer.p == null) {
      replaceStep(pillId, step, `${step} · ${t("couldn't check with {by}", { by })}`);
      return;
    }
    const state = stateOfProbability(answer.p);
    if (state === "unclear") {
      replaceStep(pillId, step, `${step} · ${t("{by} wasn't sure", { by })}`);
      return;
    }
    const checked: TestVerdict = { ...verdict, state, source: "checker" };
    replaceStep(pillId, step, verdictStep(checked, { by: answer.by, p: answer.p }));
    if (state === "failed" && State.focusId !== pillId) State.setPillBadge(pillId, "error");
  });
}

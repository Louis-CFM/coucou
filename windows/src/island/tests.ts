// Test runs an agent made → its card. The relay keeps the end of a test
// command's output; its verdict becomes a step ("Tests passed · 48 passed",
// "Tests failed · 1 failed: test_sum"), a failure badges the pill, Rust is told
// for the fix loop, and an unclear run is asked about once when the
// double-check is on (Laya here, or Jev): dotpals' "Was it tested?".

import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import {
  evidenceOf, stateOfProbability, testVerdict, verdictStep, worthChecking, type TestRun, type TestVerdict,
} from "../core/tests";
import { t } from "../i18n/i18n";

interface TestPayload {
  session_id?: string;
  tool_input?: Record<string, unknown>;
  coucou_test_output?: unknown;
  coucou_test_failed?: unknown;
  coucou_test_stopped?: unknown;
}

/** What the fix loop tells Claude when it is sent back: the counts and the failing tests. */
function summaryOf(v: TestVerdict): string {
  const f = v.facts;
  // English on purpose: this goes to Claude, not on screen.
  if (!f.parsed) return "no test summary in the output, only a failing exit code";
  const parts = [f.failed && `${f.failed} failed`, f.errors && `${f.errors} errors`, f.passed && `${f.passed} passed`].filter(Boolean);
  const names = f.failing.slice(0, 3).map((n) => String(n).split("::").pop());
  return parts.join(", ") + (names.length ? `: ${names.join(", ")}` : "");
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
  const session = payload.session_id ?? "";
  void Bridge.testsNote(session, verdict.state === "failed", summaryOf(verdict));

  if (!worthChecking(verdict) || State.settings.testChecker === "off" || !State.settings.testChecker) return;
  void Bridge.testsCheck(evidenceOf(run, verdict)).then((answer) => {
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
    if (state === "failed") {
      if (State.focusId !== pillId) State.setPillBadge(pillId, "error");
      void Bridge.testsNote(session, true, `${summaryOf(verdict)} (checked by ${by})`);
    }
  });
}

// The fix loop (Settings → Agents → Make Claude fix failing tests), as dotpals
// runs it (bridge/server.js, "the fix loop", at 6f3cf5d), on dotpals' own rules
// (../core/story). The relay waits for its word (coucou_loop) at three moments
// of a Claude Code session, here or in the Claude app:
//   a test run just ended: failed → Claude is told right away; unclear → the
//     double-check first (Laya or Jev), then Claude is asked to run the tests
//     again so the result shows, and the second time it is yours to look at;
//   Claude stops, or is about to commit or push: while this request's tests
//     fail, or weren't run after its last change, it's sent back with what to
//     do. Finishing is only held up when this request changed code, and only
//     for failures it caused, not ones that were there before it started;
//   tests made to pass by changing them (an assertion taken out, a skip added,
//     an expected value changed) are caught, from the edits and from git's view
//     of the test files.
// At most twice per request (it counts again from your next prompt), then it's
// let go and the card says so. Coucou never changes a file: it only tells
// Claude Code. Its words to Claude are English, like the rest of what Claude reads.

import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import {
  changedCode, checkOf, isTestFile, list, onlyOldFailures, parts, ships, stepType, testEvidence, testState,
  testVerdict, weakenedTests,
} from "../core/story";
import { baseName } from "../core/storyrecap";
import { failureReason } from "../core/testout";
import { stateOfProbability } from "../core/tests";
import { t } from "../i18n/i18n";
import { checkFor } from "./tests";

interface LoopPayload {
  hook_event_name?: string;
  session_id?: string;
  cwd?: string;
  tool_name?: string;
  tool_use_id?: string;
  tool_input?: Record<string, unknown>;
  coucou_agent?: string;
  coucou_test_output?: unknown;
  coucou_test_stopped?: unknown;
  error?: unknown;
  is_interrupt?: unknown;
}

/** A step as dotpals' rules read it (its Claude Code adapter's describeTool). */
interface Step {
  id: string;
  at: number;
  kind: string;
  tool?: string;
  status: "running" | "ok" | "failed" | "stopped";
  title?: string;
  files?: { path: string; change: string }[];
  body: { command?: string; output?: string; patch?: string; testDiff?: Record<string, string> | null };
  error?: string;
  check?: { by: string; p?: number; state?: string; error?: string; ms?: number; model?: string | null };
}

/** The loop's word: Claude Code's own JSON for the relay (or none), and what the card says. */
export interface LoopDecision {
  answer: string | null;
  notes: string[];
  /** Worth a badge: you're asked to look, or Claude was let go with the tests failing. */
  alert: boolean;
}

/** A test run's verdict (dotpals' testVerdict), as far as the loop reads it. */
type Verdict = { state: string; source: string; summary?: string; reason?: string; note?: string };
const verdictOf = (e: Step) => testVerdict(e) as Verdict;

const NONE: LoopDecision = { answer: null, notes: [], alert: false };
const LOOP_MAX = 2;
const KEEP_STEPS = 600;
const KEEP_SESSIONS = 40;

interface Session {
  cwd: string;
  steps: Step[];
}

const sessions = new Map<string, Session>();
const blocks = new Map<string, number>(); // session → times it was sent back in this request
const helped = new Set<string>(); // sessions told or sent back, until a test run passes ("Fixed")
const unclear = new Map<string, number>(); // session → unreadable test runs in this request
const asked = new Set<string>(); // sessions whose request went to you
const bluff = new Map<string, { text: string; sentBack: boolean }>(); // tests made to pass by changing them

/** Claude Code, in a terminal or in the Claude app: the only agent the loop speaks to. */
const claudeCode = (p: LoopPayload) => !p.coucou_agent || p.coucou_agent === "claude-desktop";

const clip = (s: unknown, n: number) => {
  const x = String(s ?? "");
  return x.length > n ? `${x.slice(0, n - 1)}…` : x;
};

const findLast = <T>(xs: T[], ok: (x: T) => boolean): T | undefined => {
  for (let i = xs.length - 1; i >= 0; i--) if (ok(xs[i])) return xs[i];
  return undefined;
};

/** A before/after pair as patch lines, "-old" then "+new" (dotpals' toPatch). */
function toPatch(before: unknown, after: unknown, max = 6000): string {
  const lines = (s: unknown, sign: string) => (s ? String(s).replace(/\r\n/g, "\n").split("\n").map((l) => sign + l) : []);
  return clip([...lines(before, "-"), ...lines(after, "+")].join("\n"), max);
}

/** A path inside the project, relative to it; one outside stays whole, which the rules read as outside. */
function relative(path: string, cwd: string): string {
  const norm = (p: string) => p.replace(/\\/g, "/").replace(/\/+$/, "");
  const p = norm(path);
  const c = norm(cwd);
  return c && p.toLowerCase().startsWith(`${c.toLowerCase()}/`) ? p.slice(c.length + 1) : p;
}

/** What a tool call is, as dotpals' Claude Code adapter describes it. */
function describe(tool: string, input: Record<string, unknown>, cwd: string): Omit<Step, "id" | "at" | "status"> {
  const file = String(input.file_path ?? input.notebook_path ?? "");
  const edit = (kind: string, patch: string) => ({
    kind, tool, title: relative(file, cwd), files: [{ path: file, change: kind }], body: { patch },
  });
  switch (tool) {
    case "Edit":
      return edit("edit", toPatch(input.old_string, input.new_string));
    case "MultiEdit": {
      const edits = Array.isArray(input.edits) ? (input.edits as Record<string, unknown>[]) : [];
      return edit("edit", clip(edits.map((e) => toPatch(e?.old_string, e?.new_string, 2000)).join("\n@@\n"), 6000));
    }
    case "NotebookEdit":
      return edit("edit", toPatch("", input.new_source));
    case "Write":
      return edit("write", toPatch("", input.content));
    case "Bash":
    case "PowerShell":
      return { kind: "run", tool, title: clip(input.command, 80), body: { command: String(input.command ?? "") } };
    case "Read":
      return { kind: "read", tool, title: relative(file, cwd), files: [{ path: file, change: "read" }], body: {} };
  }
  return { kind: "tool", tool, title: tool, body: {} };
}

function sessionOf(id: string, cwd?: string): Session {
  let s = sessions.get(id);
  if (!s) {
    s = { cwd: cwd ?? "", steps: [] };
    sessions.set(id, s);
    if (sessions.size > KEEP_SESSIONS) forget(sessions.keys().next().value!);
  }
  if (cwd) s.cwd = cwd;
  return s;
}

function forget(id: string) {
  sessions.delete(id);
  blocks.delete(id);
  helped.delete(id);
  unclear.delete(id);
  asked.delete(id);
  bluff.delete(id);
}

function push(s: Session, step: Step) {
  s.steps.push(step);
  if (s.steps.length > KEEP_STEPS) s.steps.splice(0, s.steps.length - KEEP_STEPS);
}

/** Every step of a session, all its requests. */
const sessionSteps = (id: string) => (sessions.get(id)?.steps ?? []).filter((e) => e.kind !== "prompt");

/** When the request a session is on started (its newest prompt). */
const promptAt = (id: string) => findLast(sessions.get(id)?.steps ?? [], (e) => e.kind === "prompt")?.at ?? 0;

/** The steps of the request a session is on. */
function turnSteps(id: string): Step[] {
  const start = promptAt(id);
  return sessionSteps(id).filter((e) => e.at >= start);
}

/**
 * A request's steps for the bluff rule, with the session's last test run before
 * it when that run failed: changing that test in this request is the bluff too.
 */
function bluffSteps(id: string): Step[] {
  const start = promptAt(id);
  const before = findLast(sessionSteps(id), (e) => e.at < start && e.kind === "run" && stepType(e) === "test" && e.status !== "running");
  return before && testVerdict(before).state === "failed" ? [before, ...turnSteps(id)] : turnSteps(id);
}

/** Every Claude Code hook event, while the loop is on: what the session did, as steps. */
export function observeLoop(payload: object) {
  const p = payload as LoopPayload;
  const id = p.session_id;
  if (!id || !claudeCode(p) || !State.settings.fixFailingTests) return;
  const name = p.hook_event_name;
  if (name === "SessionEnd") {
    forget(id);
    return;
  }
  const s = sessionOf(id, p.cwd);
  const now = Date.now();
  if (name === "UserPromptSubmit") {
    push(s, { id: `${id}:prompt:${now}`, at: now, kind: "prompt", status: "ok", body: {} });
    // A new request: the loop counts again.
    blocks.delete(id);
    unclear.delete(id);
    asked.delete(id);
    bluff.delete(id);
    return;
  }
  const tool = p.tool_name;
  const use = p.tool_use_id;
  if (!tool || !use) return;
  const key = `${id}:${use}`;
  const step = s.steps.find((e) => e.id === key);
  if (name === "PreToolUse") {
    if (!step) push(s, { id: key, at: now, status: "running", ...describe(tool, p.tool_input ?? {}, s.cwd) });
    return;
  }
  if (name !== "PostToolUse" && name !== "PostToolUseFailure") return;
  const ok = name === "PostToolUse";
  // A finished edit's input is whole (the relay caps it before it runs).
  const d = describe(tool, p.tool_input ?? {}, s.cwd);
  const output = typeof p.coucou_test_output === "string" ? p.coucou_test_output : undefined;
  const stopped = p.coucou_test_stopped === true || p.is_interrupt === true;
  const done = {
    ...d,
    status: (stopped ? "stopped" : ok ? "ok" : "failed") as Step["status"],
    body: { ...d.body, ...(output ? { output } : {}) },
    ...(!ok && typeof p.error === "string" ? { error: clip(p.error, 300) } : {}),
  };
  if (step) Object.assign(step, done);
  else push(s, { id: key, at: now, ...done });
}

/** The loop's word for a relay that waits (coucou_loop_id). Never throws: no word, and Claude carries on. */
export async function decideLoop(payload: object): Promise<LoopDecision> {
  try {
    const p = payload as LoopPayload;
    const id = p.session_id;
    if (!id || !claudeCode(p) || !State.settings.fixFailingTests) return NONE;
    const name = p.hook_event_name;
    if ((name === "PostToolUse" || name === "PostToolUseFailure") && p.tool_use_id) return await testRun(p, id);
    if (name === "Stop" || name === "PreToolUse") return await gate(p, id);
  } catch (err) {
    console.error("[coucou] fix loop", err);
  }
  return NONE;
}

// ── Claude Code's own replies ─────────────────────────────────────────────────

/** A note Claude reads right after the tool (additionalContext). */
const note = (p: LoopPayload, text: string) =>
  JSON.stringify({ hookSpecificOutput: { hookEventName: p.hook_event_name, additionalContext: text } });
/** Stopping is refused: keep going, with why. */
const block = (reason: string) => JSON.stringify({ decision: "block", reason });
/** The commit or push doesn't run. */
const deny = (reason: string) =>
  JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason } });

// "Jev (Coucou's cloud test checker)": the name alone means nothing to Claude.
const checkerName = (who: string) => `${who} (Coucou's ${who === "Jev" ? "cloud" : "local"} test checker)`;
// "3 failed, 5 passed: sum adds", "checked by Jev, 80% sure", or the exit code's word.
const failedWords = (v: Verdict) =>
  v.source === "exit" ? "the command exited with an error" : (testEvidence(v) as string);
// Why the first test failed, from the run's output: "expected 3, got -1 (test/math.test.js:5)", or ''.
const failedWhy = (step: Step | undefined) => {
  const r = failureReason(`${step?.body?.output ?? ""}\n${step?.error ?? ""}`);
  return r ? `${r.why}${r.where ? ` (${r.where})` : ""}` : "";
};

/** How this session last ran its tests, without a pipe or redirect (`npm test`), if it ever did. */
function sessionTestCommand(id: string): string | null {
  const run = findLast(sessionSteps(id), (e) => e.kind === "run" && stepType(e) === "test");
  const part = run && (parts(String(run.body?.command ?? "")) as string[]).find((x) => stepType({ kind: "run", body: { command: x } }) === "test");
  return part ? part.replace(/\s+\d?>>?&?\s*\S+/g, "").trim() : null;
}

/** Git's view of the test files now (dotpals' testDiff): file → its changed lines, or null outside git. */
async function testDiff(cwd: string): Promise<Record<string, string> | null> {
  if (!cwd) return null;
  const out = await Bridge.testsGitDiff(cwd);
  if (out == null) return null;
  const files: Record<string, string> = {};
  let file: string | null = null;
  let size = 0;
  for (const raw of out.split("\n")) {
    const line = raw.replace(/\r$/, "");
    const head = /^diff --git a\/.+ b\/(.+)$/.exec(line);
    if (head) {
      file = isTestFile(head[1]) ? head[1] : null;
      continue;
    }
    if (!file || /^(?:---|\+\+\+) /.test(line) || (line[0] !== "-" && line[0] !== "+")) continue;
    // Enough to judge; a huge rewrite isn't a quiet weakening.
    if ((size += line.length + 1) > 8000) break;
    files[file] = files[file] ? `${files[file]}\n${line}` : line;
  }
  return files;
}

/**
 * What's wrong with this request's tests, if it's worth sending Claude back:
 * failing, or not run since the last change. When finishing, also: code changed
 * and no tests run at all, in a session that ran them before (so the project
 * has tests, and that's how).
 */
function testTrouble(id: string, stopping: boolean) {
  const st = testState(turnSteps(id));
  const files = () => list([...new Set((st?.since ?? []).map(baseName))]) as string;
  // Only the failures this session caused hold it back: ones it found are told, not forced.
  if (st?.state === "failing") {
    return onlyOldFailures(st.last, sessionSteps(id)) ? null : { failing: true, words: failedWords(st.verdict as Verdict), why: failedWhy(st.last) };
  }
  if (st?.state === "stale") return { failing: false, words: files() };
  const command = stopping && st?.state === "untested" && sessionTestCommand(id);
  if (command) return { failing: false, untested: true, command, words: files() };
  return null;
}

/** A test run nobody could read: run it again so it shows; the second time, it's yours to look at. */
function unclearRun(p: LoopPayload, id: string, v: Verdict, check: Step["check"]): LoopDecision {
  const n = (unclear.get(id) ?? 0) + 1;
  unclear.set(id, n);
  const unsure = typeof check?.p === "number"
    ? `${checkerName(check.by === "jev" ? "Jev" : "Laya")} wasn't sure either (${Math.round(check.p * 100)}% that they passed)` : "";
  if (n === 1) {
    return {
      answer: note(p, `Coucou: can't tell whether this test run passed: ${v.note ?? "its output doesn't show the result"}.${unsure ? ` ${unsure}.` : ""} Run the tests again without cutting their output (no | tail, head or grep), so the counts and the exit code show.`),
      notes: [t("Couldn't tell if the tests passed. Asked Claude to run them again.")],
      alert: false,
    };
  }
  if (n > 2) return NONE;
  const notes = askYou(id);
  return {
    answer: note(p, "Coucou: still can't tell whether the tests passed, so it asked the user to take a look. Tell them what you ran and what you saw."),
    notes,
    alert: notes.length > 0,
  };
}

function askYou(id: string): string[] {
  if (asked.has(id)) return [];
  asked.add(id);
  return [t("Couldn't tell whether Claude's tests passed. Please take a look.")];
}

/** A test run just ended. */
async function testRun(p: LoopPayload, id: string): Promise<LoopDecision> {
  if (p.is_interrupt === true) return NONE; // you stopped it
  const s = sessionOf(id, p.cwd);
  const step = s.steps.find((e) => e.id === `${id}:${p.tool_use_id}`);
  if (!step || stepType(step) !== "test") return NONE;
  // Git's view of the tests at this run: a test weakened by any means (sed, a script) shows.
  step.body.testDiff = await testDiff(s.cwd || p.cwd || "");
  let v = verdictOf(step);
  let checked: ReturnType<typeof checkOf> = null;
  let check: Step["check"];
  if (v.state === "unclear" && State.settings.testChecker && State.settings.testChecker !== "off") {
    // Within the relay's wait: a slow answer still reaches the card, not this reply.
    const late = new Promise<null>((r) => window.setTimeout(() => r(null), 4500));
    const answer = await Promise.race([checkFor(step.id) ?? Promise.resolve(null), late]);
    if (answer) {
      step.check = answer.p == null
        ? { by: answer.by, error: answer.error ?? "no answer", ms: answer.ms }
        : { by: answer.by, p: answer.p, state: stateOfProbability(answer.p), ms: answer.ms, model: answer.model };
      check = step.check;
      if (check.state === "passed" || check.state === "failed") {
        v = verdictOf(step);
        checked = checkOf(step);
      }
    }
  }
  if (v.state === "unclear" && v.reason !== "no-tests") return unclearRun(p, id, v, check);
  if (v.state === "passed") {
    // Green, but because the tests were changed, not the code: the bluff.
    const weak = weakenedTests([...bluffSteps(id).filter((e) => e.id !== step.id), step]);
    if (weak && !bluff.has(id)) {
      bluff.set(id, { text: weak.text, sentBack: false });
      helped.delete(id);
      return {
        answer: note(p, `Coucou: the tests pass now, but only after you changed them: ${weak.text}. Don't weaken a test to make it pass: put it back and fix the code, or tell the user why the test itself was wrong.`),
        notes: [t("Claude changed the tests to make them pass.")],
        alert: true,
      };
    }
    // The test is back as it was, and it passes: the real fix.
    if (!weak && bluff.has(id)) {
      bluff.delete(id);
      helped.delete(id);
      return { ...NONE, notes: [t("Fixed: the test is back and passes now ✓")] };
    }
    if (helped.has(id)) {
      helped.delete(id);
      return { ...NONE, notes: [t("Fixed: tests pass now ✓")] };
    }
  }
  if (v.state !== "failed") return NONE;
  // Failing before this session changed anything: found, not caused, so told, not sent
  // back. Claude's own change broke them: fix it. Nothing changed yet: maybe this
  // request only asked how the tests stand.
  const old = !checked && onlyOldFailures(step, sessionSteps(id));
  const mine = !old && changedCode(turnSteps(id));
  const why = failedWhy(step);
  helped.add(id);
  const what = checked
    ? `${checkerName(checked.who)} thinks this test run failed (${checked.sure}% sure)`
    : `this test run failed (${failedWords(v)})`;
  const next = old
    ? "These tests were failing before this session changed anything, so they aren't yours to fix unless the user asks: mention them to the user."
    : mine ? "Fix it before you finish; Coucou checks again when you stop." : "If fixing it is part of this request, fix it and run the tests again.";
  return {
    answer: note(p, `Coucou: ${what}${why ? `: ${why}` : ""}. ${next}`),
    notes: old ? [t("They were failing before Claude changed anything.")] : mine ? [t("Told Claude to fix them.")] : [],
    alert: false,
  };
}

/** Claude is about to stop, or to commit or push: sent back while the tests fail or are out of date. */
async function gate(p: LoopPayload, id: string): Promise<LoopDecision> {
  const stopping = p.hook_event_name === "Stop";
  if (!stopping) {
    // Only what puts the work in front of others (a commit, a push, a PR, a publish); not
    // `npm test && git commit`, which only commits when the tests pass.
    if (p.tool_name !== "Bash" && p.tool_name !== "PowerShell") return NONE;
    if (!ships(String(p.tool_input?.command ?? ""))) return NONE;
  }
  // The last steps may still be on their way: a moment for them.
  for (let i = 0; stopping && i < 10 && turnSteps(id).some((e) => e.status === "running"); i++) {
    await new Promise((r) => window.setTimeout(r, 100));
  }
  const notes: string[] = [];
  // Asked to run unreadable tests again, and stopping without a clear result: you're asked to look.
  if (stopping && unclear.has(id) && testState(turnSteps(id))?.state === "unclear") notes.push(...askYou(id));
  // Finishing: only code this request changed is Claude's to fix. Shipping is held back either way.
  if (stopping && !changedCode(turnSteps(id))) return { ...NONE, notes, alert: notes.length > 0 };
  // The tests pass only because they were changed: back once, to put the test back or say why.
  const weak = stopping && weakenedTests(bluffSteps(id));
  if (weak && !bluff.get(id)?.sentBack) {
    bluff.set(id, { text: weak.text, sentBack: true });
    helped.add(id);
    notes.push(t("Claude changed the tests to make them pass. Sent it back to fix the code, or say why the test was wrong."));
    return {
      answer: block(`Coucou: you made the tests pass by changing them (${weak.text}). Put the test back and fix the code, or tell the user why the test was wrong, before you finish.`),
      notes,
      alert: false,
    };
  }
  const trouble = testTrouble(id, stopping);
  if (!trouble) return { ...NONE, notes, alert: notes.length > 0 };
  const times = blocks.get(id) ?? 0;
  if (times >= LOOP_MAX) {
    if (stopping) {
      helped.add(id);
      notes.push(trouble.failing ? t("Claude stopped, but the tests still fail.") : t("Claude stopped, but the tests weren't run after its last change."));
    }
    return { ...NONE, notes, alert: stopping };
  }
  blocks.set(id, times + 1);
  helped.add(id);
  const problem = trouble.failing
    ? `the tests are failing (${trouble.words})${trouble.why ? `: ${trouble.why}` : ""}`
    : trouble.untested ? `you changed ${trouble.words} but didn't run the tests` : `you changed ${trouble.words} after the last test run`;
  const fix = trouble.failing ? "Fix them and run the tests again" : trouble.untested ? `Run \`${trouble.command}\`` : "Run the tests again";
  if (stopping) {
    notes.push(trouble.failing
      ? t("Claude tried to finish with failing tests. Sent it back to fix them.")
      : trouble.untested ? t("Claude changed code without running the tests. Sent it back to run them.")
        : t("Claude changed code after the last test run. Sent it back to run them."));
    return { answer: block(`Coucou: ${problem}. ${fix} before you finish.`), notes, alert: false };
  }
  // The commit never runs: it failed, as far as the steps go.
  const step = sessions.get(id)?.steps.find((e) => e.id === `${id}:${p.tool_use_id}`);
  if (step) {
    step.status = "failed";
    step.error = `Coucou stopped this: ${problem}`;
  }
  notes.push(trouble.failing
    ? t("Stopped a commit or push: the tests are failing.")
    : t("Stopped a commit or push: code changed after the last test run."));
  return { answer: deny(`Coucou: ${problem}. ${fix} before you commit or push.`), notes, alert: false };
}

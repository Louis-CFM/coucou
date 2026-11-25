// Mochi's room (src/core/room.ts, src/island/room.ts): the rules of the Mac's
// tests/MochiRoomTests.swift, what the island sends the room, the frames on
// the wall, and a click under the room answering through the island's own card.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import ts from "typescript";
import { installFakeDom } from "./fakedom.mjs";
import { calls, emit, internals, sent } from "./tauri.mjs";

// The island pulls in stylesheets and a few parameter properties beyond Node's type stripping.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.endsWith(".css")) return { url: new URL(specifier, context.parentURL).href, shortCircuit: true };
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true };
    if (url.includes("/src/") && url.endsWith(".ts")) {
      const { outputText } = ts.transpileModule(readFileSync(fileURLToPath(url), "utf8"), {
        compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, verbatimModuleSyntax: true },
      });
      return { format: "module", source: outputText, shortCircuit: true };
    }
    return nextLoad(url, context);
  },
});

installFakeDom();
// A real island, with nothing drawn: no frames, canvases that draw nowhere.
const noop = () => {};
const nowhere = new Proxy(function () {}, {
  get: (_t, k) => (k === Symbol.toPrimitive ? () => 0 : nowhere), apply: () => nowhere, construct: () => nowhere,
});
window.addEventListener = noop;
document.addEventListener = noop;
globalThis.requestAnimationFrame = () => 0;
const make = document.createElement.bind(document);
document.createElement = (tag) => {
  const el = make(tag);
  if (tag === "canvas") el.getContext = () => nowhere;
  return el;
};
internals.metadata = { currentWindow: { label: "island" }, currentWebview: { label: "island", windowLabel: "island" } };

const Room = await import("../src/core/room.ts");
const { State, DEFAULT_SETTINGS } = await import("../src/core/state.ts");
const { Island } = await import("../src/island/island.ts");
const { registerRoomLink } = await import("../src/island/room.ts");

/** Noon on 24 November 2026 plus `days`, local time. */
const day = (days, hour = 12) => new Date(2026, 10, 24 + days, hour);
const TODAY = day(0);

test("where Mochi stands: the door, then the desk, then the bed", () => {
  assert.equal(Room.spot(true, true), "door");
  assert.equal(Room.spot(false, true), "desk");
  assert.equal(Room.spot(false, false), "bed");
  assert.equal(Room.spot(true, false, false), "desk", "door turned off: he stays at the desk");
});

test("Mochi's face: asking at the door, asleep on the bed, the session's at the desk", () => {
  const snap = { ...Room.EMPTY_SNAPSHOT, focusState: "thinking" };
  assert.equal(Room.mochiState("door", { ...snap, approval: { question: false } }), "approval");
  assert.equal(Room.mochiState("door", { ...snap, approval: { question: true } }), "question");
  assert.equal(Room.mochiState("bed", snap), "sleeping");
  assert.equal(Room.mochiState("desk", snap), "thinking");
  assert.equal(Room.mochiState("desk", { ...snap, focusState: "finished" }), "working");
});

test("the weather at the window: the worst news wins", () => {
  assert.equal(Room.weather(["success", "success"], ["READY"]), "sun");
  assert.equal(Room.weather(["success", "failure"], ["READY"]), "rain");
  assert.equal(Room.weather(["failure"], ["ERROR", "READY"]), "storm");
  assert.equal(Room.weather(["success"], ["READY", "ERROR"]), "sun", "an older failed deploy is forgotten");
  assert.equal(Room.weather(["pending"], []), "cloudy");
  assert.equal(Room.weather([], ["BUILDING"]), "cloudy");
  assert.equal(Room.weather([], []), "clear");
  assert.equal(Room.weather(["unknown"], ["READY"]), "sun");
});

test("day and night", () => {
  assert.ok(Room.isNight(21));
  assert.ok(Room.isNight(6));
  assert.ok(!Room.isNight(7));
  assert.ok(!Room.isNight(19));
});

test("the streak plant", () => {
  assert.equal(Room.streak([], TODAY), 0);
  assert.equal(Room.streak([day(0), day(-1), day(-2, 23)], TODAY), 3);
  assert.equal(Room.streak([day(-1), day(-2)], TODAY), 2, "not started today yet: yesterday's streak counts");
  assert.equal(Room.streak([day(0), day(-2), day(-3)], TODAY), 1, "a day off breaks it");
  assert.equal(Room.streak([day(-2), day(-3)], TODAY), 0);
  assert.equal(Room.streak([day(0, 9), day(0, 18), day(-1)], TODAY), 2, "several sessions in a day count once");
  assert.deepEqual([0, 1, 2, 3, 6, 7, 30].map(Room.plant), ["seed", "sprout", "sprout", "leafy", "leafy", "bloom", "bloom"]);
});

test("today: merged minutes, approvals and denials, from the recap's history", () => {
  const s = (d) => Math.floor(d.getTime() / 1000);
  const turn = (start, minutes) => ({ agent: "claude", project: "", start: s(start), end: s(start) + minutes * 60 });
  const history = {
    turns: [turn(day(0, 9), 60), turn(new Date(2026, 10, 24, 9, 30), 60), turn(day(-1), 30)],
    decisions: [
      { agent: "claude", date: s(day(0, 10)), decision: "allow" },
      { agent: "claude", date: s(day(0, 11)), decision: "always" },
      { agent: "claude", date: s(day(0, 11)), decision: "deny" },
      { agent: "claude", date: s(day(-1)), decision: "allow" },
    ],
    prefs: { enabled: true, hideProjects: false, lastShownWeek: "" },
  };
  assert.deepEqual(Room.today(history, TODAY), { minutes: 90, allowed: 2, denied: 1, streak: 2 });
  assert.deepEqual(Room.today(null, TODAY), { minutes: 0, allowed: 0, denied: 0, streak: 0 });
  assert.equal(Room.codedLabel(134), "2 h 14");
  assert.equal(Room.codedLabel(38), "38 min");
});

test("frames: only today's paid, short star counts, hidden tools read and written", () => {
  const payments = [
    { amount: 4900, createdAt: day(0, 9).getTime(), succeeded: true },
    { amount: 3500, createdAt: day(0, 15).getTime(), succeeded: true },
    { amount: 9900, createdAt: day(0, 16).getTime(), succeeded: false },
    { amount: 1200, createdAt: day(-1).getTime(), succeeded: true },
  ];
  assert.equal(Room.paidToday(payments, TODAY), 8400);
  assert.equal(Room.shortCount(842), "842");
  assert.equal(Room.shortCount(1234), "1.2k");
  assert.equal(Room.shortCount(2000), "2k");
  assert.equal(Room.shortCount(15400), "15k");
  assert.deepEqual([...Room.hiddenTools("stripe, calcom,")], ["stripe", "calcom"]);
  assert.equal(Room.hiddenToolsRaw(new Set(["vercel", "github"])), "github,vercel");
  assert.equal(Room.hiddenTools("").size, 0);
});

const integration = (data) => ({ data, error: null, loaded: true, configured: true });

function islandWith(extra = {}) {
  return {
    tasks: [], focusTask: null, pendingApproval: null, approvalQueue: [], integrations: {}, ...extra,
  };
}

test("the island's state, cut down to what the room shows", () => {
  const claude = { id: "integration_claude", name: "my-app", state: "working" };
  const snap = Room.roomSnapshot(islandWith({
    tasks: [claude, { id: "agent_codex", name: "Codex", state: "idle" }],
    focusTask: claude,
    pendingApproval: { requestId: "r1", sessionId: "s", pillId: "integration_claude", tool: "Bash", command: "rm -rf build" },
    approvalQueue: [{}, {}],
    integrations: {
      integration_stripe: integration({ currency: "eur", payments: [{ amount: 4900, createdAt: 5, status: "succeeded" }, { amount: 1, createdAt: 6, status: "failed" }] }),
      integration_github: integration({
        totalRepos: 3, totalStars: 1234,
        pulse: { login: "me", myPRs: [], toReview: [], mainCI: [{ repo: "a", url: "", branch: "main", ci: "failure", headSha: null }], fetchedAt: 0 },
      }),
      integration_vercel: integration({ deployments: [
        { state: "READY", createdAt: 1, projectName: "old" },
        { state: "CANCELED", createdAt: 3, projectName: "cancelled" },
        { state: "ERROR", createdAt: 2, projectName: "site" },
      ] }),
      integration_n8n: integration({ id: "7", workflow: "Sync", status: "error", detail: "" }),
      integration_calcom: integration({ bookings: [{ id: "1", title: "Call", start: "2026-11-24T15:00:00Z", end: "2026-11-24T15:30:00Z" }] }),
      // Not loaded yet: nothing to show.
      integration_resend: { data: {}, error: null, loaded: false, configured: true },
    },
  }));
  assert.equal(snap.busy, true);
  assert.equal(snap.focusState, "working");
  assert.deepEqual(snap.approval, {
    requestId: "r1", pillId: "integration_claude", asker: "my-app", tool: "Bash", command: "rm -rf build", question: false, queued: 2,
  });
  assert.deepEqual(snap.stripe, { currency: "eur", payments: [{ amount: 4900, createdAt: 5, succeeded: true }, { amount: 1, createdAt: 6, succeeded: false }] });
  assert.deepEqual(snap.github, { stars: 1234, ci: ["failure"] });
  assert.deepEqual(snap.vercel.map((d) => d.project), ["site", "old"], "newest first, the cancelled one left out");
  assert.deepEqual(snap.n8n, { workflow: "Sync", success: false });
  assert.deepEqual(snap.calcom, [Date.parse("2026-11-24T15:00:00Z")]);
  assert.equal(Room.roomWeather(snap), "storm");

  const quiet = Room.roomSnapshot(islandWith({ tasks: [{ id: "x", name: "x", state: "idle" }] }));
  assert.deepEqual(quiet, { ...Room.EMPTY_SNAPSHOT });
  const asked = Room.roomSnapshot(islandWith({
    pendingApproval: { requestId: "r2", sessionId: "s", pillId: "agent_gemini", tool: "AskUserQuestion", command: "", questions: [] },
  }));
  assert.equal(asked.approval.question, true);
  assert.equal(asked.approval.asker, "Gemini CLI", "a pill not on screen is named from the catalog");
});

test("the frames on the wall: a connected, shown tool fills its slot; the others stay empty", () => {
  const now = day(0, 10);
  const snap = {
    ...Room.EMPTY_SNAPSHOT,
    stripe: { currency: "usd", payments: [{ amount: 4900, createdAt: day(0, 9).getTime(), succeeded: true }] },
    github: { stars: 15400, ci: [] },
    vercel: [{ state: "READY", createdAt: day(0, 9).getTime(), project: "site" }, { state: "ERROR", createdAt: day(0, 8).getTime(), project: "site" }],
    n8n: { workflow: "Sync", success: true },
    calcom: [day(0, 9).getTime(), day(0, 14).getTime(), day(1, 9).getTime()],
  };
  const all = new Set(["stripe", "github", "vercel", "n8n", "calcom"]);
  const f = Room.frames(snap, all, new Set(), now);
  assert.deepEqual(f.map((x) => x?.tool.id), ["stripe", "github", "vercel", "n8n", "calcom"]);
  assert.match(f[0].value, /49/);
  assert.equal(f[0].label, "Today");
  assert.equal(f[1].value, "★ 15k");
  assert.deepEqual([f[2].value, f[2].label, f[2].dot], ["Ready", "site", "green"]);
  assert.deepEqual([f[3].value, f[3].label, f[3].dot], ["Sync", "Last run", "green"]);
  assert.equal(f[4].value, day(0, 14).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }), "the next call today, not a past one");
  assert.equal(Room.deploysToday(snap, now), "1 / 2");

  const some = Room.frames(snap, new Set(["github", "vercel"]), new Set(["vercel"]), now);
  assert.deepEqual(some.map((x) => x?.tool.id ?? null), [null, "github", null, null, null]);
  const empty = Room.frames(Room.EMPTY_SNAPSHOT, all, new Set(), now);
  assert.deepEqual(empty.map((x) => x.value), ["–", "–", "–", "–", "–"]);
  assert.equal(Room.deploysToday(Room.EMPTY_SNAPSHOT, now), "–");
});

// ── The island's side ────────────────────────────────────────────────────────

const island = new Island(document.createElement("div"));
const alerts = [];
const realAlert = island.alert.bind(island);
island.alert = (view) => {
  alerts.push(view);
  realAlert(view);
};
registerRoomLink(island);

const toRoom = () => sent("plugin:event|emit_to").filter((a) => a.event === "room-state");

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  calls.length = 0;
  alerts.length = 0;
  State.settings = { ...DEFAULT_SETTINGS };
  State.tasks = [];
  State.approvalQueue = [];
  State.pendingApproval = null;
  State.loadIntegrationTasks();
});

afterEach(() => {
  emit("room-watch", false);
  mock.timers.reset();
});

test("the island sends nothing until the room watches, then each change once, then nothing again", () => {
  State.notify();
  mock.timers.tick(1000);
  assert.equal(toRoom().length, 0, "not watched: nothing sent");

  emit("room-watch", true);
  assert.equal(toRoom().length, 1, "the whole picture at once");
  assert.equal(toRoom()[0].target.label, "settings");

  State.upsertExternalAgent("agent_gemini", "Gemini CLI", "#fff");
  State.updateTask("agent_gemini", "working");
  State.appendStep("agent_gemini", "Reads · a.ts");
  mock.timers.tick(300);
  assert.equal(toRoom().length, 2, "a burst of changes is one message");
  assert.equal(toRoom()[1].payload.busy, true);

  State.notify();
  mock.timers.tick(300);
  assert.equal(toRoom().length, 2, "nothing new: nothing sent");

  emit("room-watch", false);
  State.updateTask("agent_gemini", "idle");
  mock.timers.tick(1000);
  assert.equal(toRoom().length, 2, "no longer watched: nothing sent");
});

test("Allow and Deny under the room send what the island's own card sends", () => {
  State.pendingApproval = { requestId: "r1", sessionId: "s", pillId: "integration_claude", tool: "Bash", command: "ls" };
  emit("room-decide", { requestId: "r1", decision: "allow" });
  assert.deepEqual(sent("approval_decision"), [{ requestId: "r1", decision: "allow" }]);
  assert.equal(State.pendingApproval, null, "the card goes, as after a click in the island");

  State.pendingApproval = { requestId: "r2", sessionId: "s", pillId: "integration_claude", tool: "Bash", command: "ls" };
  emit("room-decide", { requestId: "r2", decision: "deny" });
  assert.deepEqual(sent("approval_decision")[1], { requestId: "r2", decision: "deny" });
});

test("a stale click, a question, or something else than a decision answers nothing", () => {
  State.pendingApproval = { requestId: "r3", sessionId: "s", pillId: "integration_claude", tool: "Bash", command: "ls" };
  emit("room-decide", { requestId: "r-old", decision: "allow" });
  emit("room-decide", { requestId: "r3", decision: "always" });
  emit("room-decide", null);
  State.pendingApproval = {
    requestId: "r4", sessionId: "s", pillId: "integration_claude", tool: "AskUserQuestion", command: "",
    questions: [{ question: "Which?", options: [], multiSelect: false }],
  };
  emit("room-decide", { requestId: "r4", decision: "allow" });
  assert.deepEqual(sent("approval_decision"), []);
  assert.deepEqual(sent("approval_decline"), []);
});

test("Antigravity's Reply in terminal hands the command back, as the island's button does", () => {
  State.pendingApproval = { requestId: "r5", sessionId: "s", pillId: "agent_antigravity", tool: "run_command", command: "npm i" };
  emit("room-decide", { requestId: "r5", decision: "terminal" });
  assert.deepEqual(sent("approval_decline"), [{ requestId: "r5" }]);
  assert.deepEqual(sent("approval_decision"), []);
});

test("Open the island brings up the card waiting there", () => {
  State.pendingApproval = {
    requestId: "r6", sessionId: "s", pillId: "integration_claude", tool: "AskUserQuestion", command: "",
    questions: [{ question: "Which?", options: [], multiSelect: false }],
  };
  emit("room-open-island", null);
  assert.deepEqual(alerts, ["question"]);
});

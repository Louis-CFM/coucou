// Plan usage gauges (src/core/plan.ts, src/views/usage.ts): a port of the Mac's
// tests/ClaudePlanGaugeTests.swift, the Codex parsing of CodexPlanGauge.swift,
// and the pills' rules (where they show, what a click opens, what closes it).

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import {
  claudeSubtitle, codexIsStale, codexResetsLabel, codexSubtitle, dominantPct, effectivePct,
  parseClaudePlan, parseCodexPlan, pillLabel, planColor, resetLabel, restorePlanUsage,
} from "../src/core/plan.ts";
import { emit } from "./tauri.mjs";
import { registerHookHandlers } from "../src/island/hooks.ts";
import {
  claudePillVisible, codexPillVisible, openPlanColor, planCardOpen,
} from "../src/views/usage.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

const NOW = Date.UTC(2026, 9, 7, 12, 0, 0);
const future = NOW / 1000 + 7200; // 2 hours from now, epoch seconds
const past = NOW / 1000 - 100;
const claude = (rl) => parseClaudePlan(rl, NOW);
const win = (pct, epochS) => ({ usedPct: pct, resetsAt: epochS * 1000 });

// ── ClaudePlanGauge.parse ─────────────────────────────────────────────────────

test("a full payload gives both windows", () => {
  const u = claude({
    five_hour: { used_percentage: 23.5, resets_at: future },
    seven_day: { used_percentage: 67.0, resets_at: future },
  });
  assert.equal(u.fiveHour.usedPct, 23.5);
  assert.equal(u.sevenDay.usedPct, 67);
  assert.equal(u.fiveHour.resetsAt, future * 1000);
  assert.equal(u.updatedAt, NOW);
});

test("missing or empty rate_limits is nothing", () => {
  assert.equal(claude(undefined), null);
  assert.equal(claude({}), null);
  assert.equal(claude("x"), null);
});

test("percentages: 150 is shown full, above 200 or below 0 is dropped, ints are fine", () => {
  const one = (pct) => claude({ five_hour: { used_percentage: pct, resets_at: future } })?.fiveHour;
  assert.equal(one(250), undefined);
  assert.equal(one(201), undefined);
  assert.equal(one(-5), undefined);
  assert.equal(one(150).usedPct, 100);
  assert.equal(one(42).usedPct, 42);
  assert.equal(one("42"), undefined);
});

test("a reset more than 400 days away is milliseconds in disguise", () => {
  const far = NOW / 1000 + 401 * 86400;
  assert.equal(claude({ five_hour: { used_percentage: 50, resets_at: far } }), null);
  assert.equal(claude({ five_hour: { used_percentage: 50, resets_at: NOW } }), null);
  assert.equal(claude({ five_hour: { used_percentage: 50, resets_at: 0 } }), null);
});

test("one good window is enough", () => {
  const u = claude({
    five_hour: { used_percentage: 250, resets_at: future },
    seven_day: { used_percentage: 10, resets_at: future },
  });
  assert.equal(u.fiveHour, undefined);
  assert.equal(u.sevenDay.usedPct, 10);
});

// ── effectivePct / dominantPct ────────────────────────────────────────────────

test("a window whose reset has passed counts as 0", () => {
  assert.equal(effectivePct(win(80, past), NOW), 0);
  assert.equal(effectivePct(win(80, future), NOW), 80);
});

test("the dominant percentage is the higher window", () => {
  const both = { fiveHour: win(30, future), sevenDay: win(70, future), updatedAt: NOW };
  const fhOnly = { fiveHour: win(55, future), updatedAt: NOW };
  const empty = { updatedAt: NOW };
  assert.equal(dominantPct(both, NOW), 70);
  assert.equal(dominantPct(fhOnly, NOW), 55);
  assert.equal(dominantPct(empty, NOW), null);
  assert.equal(dominantPct(null, NOW), null);
  // An expired week no longer dominates.
  assert.equal(dominantPct({ fiveHour: win(30, future), sevenDay: win(90, past), updatedAt: NOW }, NOW), 30);
});

// ── color / labels ────────────────────────────────────────────────────────────

test("colours: grey, then green below 50, orange below 80, red", () => {
  assert.equal(planColor(null), "#6B7079");
  assert.equal(planColor(0), "#22C55E");
  assert.equal(planColor(49), "#22C55E");
  assert.equal(planColor(50), "#F59E0B");
  assert.equal(planColor(79), "#F59E0B");
  assert.equal(planColor(80), "#F4505E");
  assert.equal(planColor(100), "#F4505E");
});

test("pill labels read like the Mac's header pill", () => {
  const both = { fiveHour: win(30, future), sevenDay: win(70, future), updatedAt: NOW };
  assert.equal(pillLabel("Claude", null, NOW), "Claude —");
  assert.equal(pillLabel("Claude", { updatedAt: NOW }, NOW), "Claude —");
  assert.equal(pillLabel("Claude", both, NOW), "Claude 70%");
  assert.equal(pillLabel("Codex", { sevenDay: win(12.4, future), updatedAt: NOW }, NOW), "Codex 12%");
  assert.equal(pillLabel("Codex", null, NOW), "Codex —");
});

test("reset times: a countdown for 5 hours, a weekday for the week", () => {
  assert.equal(resetLabel(win(10, NOW / 1000 + 4800), false, NOW), "in 1 h 20");
  assert.equal(resetLabel(win(10, NOW / 1000 + 300), false, NOW), "in 5 min");
  assert.equal(resetLabel(win(10, past), false, NOW), "Resetting…");
  const at = new Date(2026, 9, 12, 9, 5); // a Monday, local time
  assert.equal(resetLabel({ usedPct: 1, resetsAt: at.getTime() }, true, at.getTime() - 3600_000), "Mon 9:05");
});

test("subtitles say how old the numbers are", () => {
  assert.equal(claudeSubtitle(null, NOW), "Waiting for a response from Claude Code");
  assert.equal(claudeSubtitle({ updatedAt: NOW - 30_000 }, NOW), "just now");
  assert.equal(claudeSubtitle({ updatedAt: NOW - 12 * 60_000 }, NOW), "12 min ago");
  assert.equal(claudeSubtitle({ updatedAt: NOW - 3 * 3600_000 }, NOW), "3 h ago");
  assert.equal(codexSubtitle(null, NOW), "Asking Codex…");
  assert.equal(codexSubtitle({ planType: "plus", updatedAt: NOW - 120_000 }, NOW), "plus · 2 min ago");
});

test("the last Claude numbers survive a restart, and junk does not", () => {
  const u = { fiveHour: win(30, future), updatedAt: NOW };
  assert.deepEqual(restorePlanUsage(JSON.stringify(u)), u);
  assert.equal(restorePlanUsage(null), null);
  assert.equal(restorePlanUsage("{"), null);
  assert.equal(restorePlanUsage(JSON.stringify({ updatedAt: NOW, fiveHour: { usedPct: 900, resetsAt: 1 } })), null);
});

// ── CodexPlanGauge.parse ──────────────────────────────────────────────────────

test("Codex windows are sorted by duration, not by primary/secondary", () => {
  const u = parseCodexPlan({
    rateLimits: {
      planType: "plus",
      primary: { usedPercent: 64, resetsAt: future + 86400, windowDurationMins: 10080 },
      secondary: { usedPercent: 12.5, resetsAt: future, windowDurationMins: 300 },
    },
  }, NOW);
  assert.equal(u.planType, "plus");
  assert.equal(u.fiveHour.usedPct, 12.5);
  assert.equal(u.sevenDay.usedPct, 64);
  assert.equal(u.sevenDay.resetsAt, (future + 86400) * 1000);
});

test("a Codex window without a duration is the week; percentages are clamped", () => {
  const u = parseCodexPlan({ rateLimits: { primary: { usedPercent: 140, resetsAt: future } } }, NOW);
  assert.equal(u.fiveHour, undefined);
  assert.equal(u.sevenDay.usedPct, 100);
  const low = parseCodexPlan({ rateLimits: { primary: { usedPercent: -3, resetsAt: future } } }, NOW);
  assert.equal(low.sevenDay.usedPct, 0);
});

test("free resets: the count and the soonest available expiry", () => {
  const u = parseCodexPlan({
    rateLimits: { primary: { usedPercent: 5, resetsAt: future, windowDurationMins: 10080 } },
    rateLimitResetCredits: {
      availableCount: 2,
      credits: [
        { status: "available", expiresAt: Date.UTC(2026, 10, 20, 12) / 1000 },
        { status: "used", expiresAt: Date.UTC(2026, 9, 1, 12) / 1000 },
        { status: "available", expiresAt: Date.UTC(2026, 9, 9, 12) / 1000 },
      ],
    },
  }, NOW);
  assert.equal(u.resetCredits, 2);
  assert.equal(u.resetCreditExpiresAt, Date.UTC(2026, 9, 9, 12));
  assert.equal(codexResetsLabel(u), "2 available · until Oct 9");
  assert.equal(codexResetsLabel({ ...u, resetCredits: 0 }), "0 available");
  assert.equal(codexResetsLabel({ updatedAt: NOW }), "—");
  assert.equal(codexResetsLabel(null), "—");
});

test("no Codex limits, or only broken ones, is nothing", () => {
  assert.equal(parseCodexPlan(null, NOW), null);
  assert.equal(parseCodexPlan({}, NOW), null);
  assert.equal(parseCodexPlan({ rateLimits: { primary: { usedPercent: "5", resetsAt: future } } }, NOW), null);
  assert.equal(parseCodexPlan({ rateLimits: { primary: { usedPercent: 5 } } }, NOW), null);
});

test("Codex is asked again only once its numbers are a minute old", () => {
  assert.equal(codexIsStale(null, NOW), true);
  assert.equal(codexIsStale({ updatedAt: NOW - 59_000 }, NOW), false);
  assert.equal(codexIsStale({ updatedAt: NOW - 60_000 }, NOW), true);
});

// ── The pills in the island ───────────────────────────────────────────────────

registerHookHandlers({ alert() {}, setView() {}, reveal() {}, dropPin() {} });

beforeEach(() => {
  State.settings = { ...DEFAULT_SETTINGS };
  State.view = "overview";
  State.paused = false;
  State.planUsage = null;
  State.codexPlanUsage = null;
  State.showingPlanDetail = false;
  State.planDetailIsCodex = false;
});

test("both pills are off by default, so the header is as it shipped", () => {
  assert.equal(claudePillVisible(), false);
  assert.equal(codexPillVisible(), false);
});

test("the Claude pill needs the switch and the relay, and the overview", () => {
  State.settings.showPlanInNotch = true;
  assert.equal(claudePillVisible(), false);
  State.settings.planRelayInstalled = true;
  assert.equal(claudePillVisible(), true);
  State.view = "prompt";
  assert.equal(claudePillVisible(), false);
});

test("the Codex pill needs only its switch, on the overview", () => {
  State.settings.showCodexPlanInNotch = true;
  assert.equal(codexPillVisible(), true);
  State.view = "settings";
  assert.equal(codexPillVisible(), false);
});

test("an open card follows its pill, and Nova wears that plan's colour", () => {
  State.settings.showPlanInNotch = true;
  State.settings.planRelayInstalled = true;
  State.showingPlanDetail = true;
  assert.equal(planCardOpen(), true);
  assert.equal(openPlanColor(), "#6B7079");
  // The Codex card cannot be open without its pill.
  State.planDetailIsCodex = true;
  assert.equal(planCardOpen(), false);
  State.settings.showCodexPlanInNotch = true;
  assert.equal(planCardOpen(), true);
  State.codexPlanUsage = { sevenDay: win(85, Date.now() / 1000 + 3600), updatedAt: Date.now() };
  assert.equal(openPlanColor(), "#F4505E");
});

test("focusing another pill closes the plan card", () => {
  State.loadIntegrationTasks();
  State.showingPlanDetail = true;
  State.setFocus(State.tasks[0].id);
  assert.equal(State.showingPlanDetail, false);
});

test("a status line call updates the numbers and nothing else, even when paused", () => {
  State.paused = true;
  const tasks = JSON.stringify(State.tasks);
  emit("hook", {
    hook_event_name: "StatusLine",
    session_id: "s1",
    rate_limits: { five_hour: { used_percentage: 42, resets_at: Date.now() / 1000 + 3600 } },
  });
  assert.equal(State.planUsage.fiveHour.usedPct, 42);
  assert.equal(JSON.stringify(State.tasks), tasks);
  // Without limits (API-key users) the last numbers stay.
  emit("hook", { hook_event_name: "StatusLine", session_id: "s1" });
  assert.equal(State.planUsage.fiveHour.usedPct, 42);
});

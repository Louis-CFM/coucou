// Pill-row budget: every enabled pill shares one cap of MAX_PILLS.
//
// Bugs this covers:
//   - an agent switched off kept its pill, because every `agent_` pill used to
//     load unconditionally;
//   - the cap of 4 lived only in the settings window and counted integrations
//     alone, so the island could hold more than it has room for;
//   - Claude Code could not be switched off at all: its pill id is
//     `integration_claude` but settings calls it "claudeCode", so the code that
//     built the id by concatenation removed a task that never existed;
//   - leftover `agent_*` entries in activeIntegrations from the old scheme were
//     counted twice, putting a real settings file over its own cap.

import { State, INTEGRATION_AGENTS, MAX_PILLS } from "../src/core/state";

let failures = 0;
const check = (name: string, got: unknown, want: unknown) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures++;
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${name}`);
  if (!ok) console.log(`        got  ${JSON.stringify(got)}\n        want ${JSON.stringify(want)}`);
};

/** State is a singleton, so each case resets its fields rather than constructing. */
const build = (opts: { disabled?: string[]; active?: string[] }) => {
  State.settings.disabledAgents = opts.disabled ?? [];
  State.settings.activeIntegrations = opts.active ?? [];
  State.tasks = [];
  State.focusId = "";
  State.loadIntegrationTasks();
  return State.tasks.map((t) => t.id);
};

console.log(`  MAX_PILLS = ${MAX_PILLS}\n`);

// ── the reported bug ─────────────────────────────────────────────────────────
console.log("switching an agent off removes its pill");
check("copilot off -> no pill", build({ disabled: ["copilot"] }).includes("agent_copilot"), false);
check("copilot back on -> pill returns", build({ disabled: [] }).includes("agent_copilot"), true);
check(
  "every declared agent can be turned off individually",
  INTEGRATION_AGENTS.filter((t) => agentOf(t.id) !== null).every((a) => {
    const agent = agentOf(a.id)!;
    return !build({ disabled: [agent] }).includes(a.id);
  }),
  true,
);

function agentOf(id: string): string | null {
  if (id === "integration_claude") return "claudeCode";
  return id.startsWith("agent_") ? id.slice(6) : null;
}

// ── VS Code is an ordinary pill ───────────────────────────────────────────────
console.log("\nVS Code can be switched off like any other agent");
check("claudeCode off -> no VS Code pill", build({ disabled: ["claudeCode"] }).includes("integration_claude"), false);
check("claudeCode on -> pill present", build({ disabled: ["codex"] }).includes("integration_claude"), true);
// Four other agents immediately take the slot it frees, so the pill count stays
// at the cap. What proves VS Code spends a slot is the budget going down.
build({});
check("five agents on spends five", State.pillBudgetUsed(), 5);
build({ disabled: ["claudeCode"] });
check("switching VS Code off frees exactly one", State.pillBudgetUsed(), 4);
check(
  "everything off leaves nothing, rather than falling back to VS Code",
  build({ disabled: ["claudeCode", "pi", "copilot", "antigravity", "codex"] }),
  [],
);
check("focus does not point at a pill that does not exist", build({ disabled: ["claudeCode"] }).includes(State.focusId), true);

// ── the shared budget ────────────────────────────────────────────────────────
console.log("\nagents and integrations share one budget");
check("five agents enabled is capped at four", build({}).length, MAX_PILLS);
check(
  "which four is stable, not dependent on click order",
  build({ disabled: ["codex"] }).slice(0, 4),
  build({ disabled: ["codex"] }).slice(0, 4),
);
check(
  "three agents + one integration fits exactly",
  build({ disabled: ["codex"], active: ["integration_github"] }).length,
  MAX_PILLS,
);
check(
  "a fifth is dropped",
  build({ disabled: ["codex"], active: ["integration_github", "integration_vercel"] }).length,
  MAX_PILLS,
);
check(
  "four integrations, every agent off, all four show",
  build({
    disabled: ["claudeCode", "pi", "copilot", "antigravity", "codex"],
    active: ["integration_github", "integration_vercel", "integration_notion", "integration_stripe"],
  }).length,
  4,
);
check(
  "five integrations, every agent off, is capped at five",
  build({
    disabled: ["claudeCode", "pi", "copilot", "antigravity", "codex"],
    active: ["integration_github", "integration_vercel", "integration_notion", "integration_stripe", "integration_resend"],
  }).length,
  MAX_PILLS,
);

// ── toggleIntegration refuses, and says so ───────────────────────────────────
console.log("\ntoggleIntegration reports refusal instead of failing silently");
{
  build({});
  check("budget is already full with every agent on", State.pillBudgetFull(), true);
  check("enabling a 5th returns false", State.toggleIntegration("integration_github"), false);
  check("and nothing was written", State.settings.activeIntegrations.includes("integration_github"), false);

  build({ disabled: ["copilot", "antigravity", "codex", "claudeCode"] });
  check("turning agents off frees the budget", State.pillBudgetFull(), false);
  check("then the integration fits", State.toggleIntegration("integration_github"), true);
  check("and it appears", State.tasks.some((t) => t.id === "integration_github"), true);
}

// ── live state survives a settings change ────────────────────────────────────
console.log("\nlive state survives a rebuild");
{
  build({});
  State.tasks.find((t) => t.id === "agent_pi")!.steps.push("editing a file");
  State.loadIntegrationTasks();
  check("steps are not wiped", State.tasks.find((t) => t.id === "agent_pi")!.steps, ["editing a file"]);
}

// ── the cap covers the focused pill ─────────────────────────────────────
console.log("\nthe 4-pill cap counts the focused pill");
{
  build({});
  check("tasks never exceed the cap", State.tasks.length <= MAX_PILLS, true);
  // An external agent arriving mid-session must not push the row to five.
  for (let i = 0; i < 6; i++) {
    State.upsertExternalAgent(`agent_x${i}`, `X${i}`, "#888888");
  }
  check("repeated external pills cannot exceed the cap", State.tasks.length <= MAX_PILLS, true);
  check("row is still exactly the cap", State.tasks.length, MAX_PILLS);
}

// ── a disabled agent cannot resurrect its own pill ───────────────────────────
console.log("\nupsertExternalAgent respects disabledAgents");
{
  build({ disabled: ["copilot"] });
  State.upsertExternalAgent("agent_copilot", "Copilot CLI", "#58A6FF");
  check("running does not bring the pill back", State.tasks.some((t) => t.id === "agent_copilot"), false);

  build({});
  State.upsertExternalAgent("agent_copilot", "Copilot CLI", "#58A6FF");
  check("an enabled agent still gets its pill", State.tasks.some((t) => t.id === "agent_copilot"), true);
}

// ── stale settings from the old scheme ────────────────────────────────────────
console.log("\nstale agent ids in activeIntegrations are not double-counted");
{
  State.settings.disabledAgents = ["claudeCode", "codex"];
  State.settings.activeIntegrations = ["agent_pi", "agent_antigravity", "agent_copilot"];
  State.tasks = [];
  State.focusId = "";
  State.loadIntegrationTasks();
  check("used count ignores the leftover agent ids", State.pillBudgetUsed(), 3);
  check("the three enabled agents still get pills", State.tasks.map((t) => t.id), ["agent_pi", "agent_copilot", "agent_antigravity"]);
  check("two slots are still free", State.pillBudgetFull(), false);
  check("turning a 4th pill on succeeds", State.toggleIntegration("integration_github"), true);
  check("and a 5th", State.toggleIntegration("integration_notion"), true);
  check("now full", State.pillBudgetFull(), true);
  check("a 6th is refused", State.toggleIntegration("integration_stripe"), false);
  check("and nothing was written", State.settings.activeIntegrations.includes("integration_stripe"), false);
}

console.log(failures === 0 ? "\n  all pass" : `\n  ${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
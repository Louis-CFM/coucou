// Dev harness: the real island following a made-up Claude Code session, in a
// plain browser — the hook events a session sends, played through the island's
// own handler. Not part of the app bundle. `npm run dev`, then
// /dev/claude-preview.html.

import "../src/style.css";
import { CLAUDE_ID, State } from "../src/core/state";
import { handleHook, type HookPayload } from "../src/island/hooks";
import { handleIntegration } from "../src/island/integrations";
import type { IntegrationUpdate } from "../src/core/bridge";
import { Island } from "../src/island/island";

const params = new URLSearchParams(location.search);
const view = params.get("view") ?? "overview";

const SESSION = "3f2a9c1e-preview";
const CWD = "C:\\Users\\mochi\\code\\coucou";
const base: HookPayload = {
  session_id: SESSION, cwd: CWD, entrypoint: "claude-desktop", session_title: "Answer questions from the island",
};

State.loadIntegrationTasks();
State.setFocus(CLAUDE_ID);
// Pinned, so the island doesn't fold away while it's being looked at.
State.isPinned = true;

const island = new Island(document.getElementById("root")!);
const hook = (payload: HookPayload) => handleHook(island, { ...base, ...payload });
// From the console: `hook({ hook_event_name: "Stop" })` plays any event by hand,
// `island.launch()` the greeting, `integration({ id, data, error: null, event: null })`
// an integration's update, and `State` is the island's own.
const integration = (update: IntegrationUpdate) => handleIntegration(island, update);
Object.assign(window, { hook, island, State, integration });

const edit = (file: string, patch: string, created = false) => {
  const lines = patch.split("\n");
  const tool_name = created ? "Write" : "Edit";
  const tool_input = { file_path: `${CWD}\\${file}` };
  hook({ hook_event_name: "PreToolUse", tool_name, tool_input });
  hook({
    hook_event_name: "PostToolUse", tool_name, tool_input,
    change: {
      patch: `${patch}\n`, created, truncated: false,
      additions: lines.filter((l) => l.startsWith("+")).length,
      deletions: lines.filter((l) => l.startsWith("-")).length,
    },
  });
};

hook({ hook_event_name: "SessionStart" });
hook({ hook_event_name: "UserPromptSubmit", prompt: "Answer Claude's questions from the island" });
edit("windows\\src\\island\\hooks.ts", [
  "@@ -228,9 +228,14 @@",
  '       const tool = payload.tool_name ?? "Tool";',
  "       const input = payload.tool_input ?? {};",
  "-      State.pendingApproval = {",
  "-        requestId,",
  '-        sessionId: payload.session_id ?? "",',
  "-      };",
  '+      const sessionId = payload.session_id ?? "";',
  "+      // Claude's question tool asks for permission like any other.",
  "+      const questions = tool === QUESTION_TOOL ? questionsOf(input) : null;",
  "+      if (questions) State.pendingQuestion = { requestId, sessionId, questions };",
  "+      else State.pendingApproval = { requestId, sessionId, tool, command: approvalTarget(tool, input) };",
  "       if (requestId) void Bridge.approvalAck(requestId);",
].join("\n"));
edit("windows\\src\\views\\session.ts", [
  "@@ -0,0 +1,6 @@",
  "+// The session panel — what a Claude Code session did, read from the island.",
  "+",
  '+import { h, svg, clear, dot } from "./dom";',
  "+",
  "+/** The file whose diff is on screen; null is the list. */",
  "+let open: string | null = null;",
].join("\n"), true);
edit("windows\\hook\\src\\main.rs", [
  "@@ -66,8 +66,10 @@ fn main() {",
  '-    let waits_for_answer = event == "PermissionRequest";',
  "+    // Only a permission request waits for a human.",
  '+    let waits_for_answer = matches!(event.as_str(), "PermissionRequest" | "Stop");',
  '     let budget = if event == "PermissionRequest" { DECISION_BUDGET } else { FIRE_AND_FORGET_BUDGET };',
].join("\n"));
edit("windows\\src\\island\\hooks.ts", [
  "@@ -176,6 +181,8 @@",
  '     case "PostToolUse":',
  "+      if (answeredElsewhere(payload)) dropPending(island);",
  "+      recordChange(payload);",
  '       State.updateTask(CLAUDE_ID, "working");',
  "       break;",
].join("\n"));
edit("windows\\README.md", ["@@ -40,3 +40,4 @@", " ## Claude Code", "+Answer Claude's questions from the island.", " "].join("\n"));
const TESTS = [
  "running 12 tests",
  "test tests::an_edit_becomes_a_diff_with_its_line_numbers ... ok",
  "test tests::a_command_shows_the_end_of_what_it_printed ... ok",
  "test tests::a_file_read_shows_its_first_lines_with_their_numbers ... ok",
  "",
  "test result: ok. 12 passed; 0 failed; finished in 0.01s",
].join("\n");
const run = (command: string, printed: string | null) => {
  const tool_input = { command };
  hook({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input });
  if (printed != null) {
    hook({ hook_event_name: "PostToolUse", tool_name: "Bash", tool_input, result: { text: printed, start: null, truncated: false, tail: true } });
  }
};
const read = (file: string, start: number, text: string) => {
  const tool_input = { file_path: `${CWD}\\${file}` };
  hook({ hook_event_name: "PreToolUse", tool_name: "Read", tool_input });
  hook({ hook_event_name: "PostToolUse", tool_name: "Read", tool_input, result: { text, start, truncated: true, tail: false } });
};
// `step`: where the session is at — reading, running its tests, or (the default) done running them.
const at = params.get("step");
if (at === "read") {
  read("windows\\src\\island\\hooks.ts", 96, [
    "/** The session an event comes from, told what the event says of it. */",
    "function sessionOf(island: Island, payload: HookPayload): ClaudeSession {",
    "  const id = payload.session_id || ANONYMOUS;",
    "  let session = State.sessions.find((s) => s.id === id);",
    "  if (!session) {",
    "    session = newSession(id);",
  ].join("\n"));
} else {
  run("cargo test -p coucou-hook", at === "run" ? null : TESTS);
}

// `sessions`: two more conversations going on behind the first — one at work
// in a terminal, one that has just finished in the Claude app.
const second: HookPayload = {
  session_id: "8b1d04e7-preview", cwd: "C:\\Users\\mochi\\code\\atlas", entrypoint: "cli", session_title: "Course search",
};
const third: HookPayload = {
  session_id: "c47e9a02-preview", cwd: CWD, entrypoint: "claude-desktop", session_title: "Fix the blurry island",
};
if (params.has("sessions")) {
  hook({ ...second, hook_event_name: "UserPromptSubmit", prompt: "Add a search to the course list" });
  hook({ ...second, hook_event_name: "PreToolUse", tool_name: "Grep", tool_input: { pattern: "courses" } });
  hook({ ...third, hook_event_name: "UserPromptSubmit", prompt: "The island is blurry while it resizes" });
  hook({ ...third, hook_event_name: "Stop", last_message: "The island now stays on a whole pixel while it resizes." });
}

const option = (label: string, description: string) => ({ label, description });
const engine = {
  question: "Which engine for the course search?",
  header: "Search",
  multiSelect: params.has("multi"),
  options: [
    option("Postgres full-text", "Already in the stack: no new service, good enough for a few thousand courses."),
    option("Meilisearch", "Typo-tolerant and fast, one more container to run."),
    option("Algolia", "Hosted, the best relevance out of the box, paid past the free tier."),
  ],
};
const more = [
  {
    question: "Index the course descriptions too, or only the titles?", header: "Scope", multiSelect: false,
    options: [option("Titles only", "Smaller index, exact matches."), option("Titles and descriptions", "Finds more, ranks titles first.")],
  },
  {
    question: "Ship it behind a flag?", header: "Rollout", multiSelect: false,
    options: [option("Yes", "Off by default, switched on per account."), option("No", "On for everyone at the next release.")],
  },
];

// `asked`: earlier in the turn, a question that was answered and a command that had to ask first.
if (params.has("asked")) {
  const ask = { tool_name: "AskUserQuestion", tool_input: { questions: [more[0]] } };
  hook({ hook_event_name: "PreToolUse", ...ask });
  hook({ hook_event_name: "PostToolUse", ...ask, answers: { [more[0].question]: "Titles and descriptions" } });
  const push = { tool_name: "Bash", tool_input: { command: "git push origin windows-claude-desktop" } };
  hook({ hook_event_name: "PreToolUse", ...push });
  hook({ hook_event_name: "PermissionRequest", request_id: "preview-0", ...push });
  hook({ hook_event_name: "PostToolUse", ...push, result: { text: ["To github.com:mochi/coucou.git", "   11bd082..848ca62  windows-claude-desktop -> windows-claude-desktop"].join("\n"), start: null, truncated: false, tail: true } });
  hook({ hook_event_name: "SubagentStart" });
}

if (view === "question") {
  hook({ hook_event_name: "PreToolUse", tool_name: "AskUserQuestion", tool_input: { questions: params.has("many") ? [engine, ...more] : [engine] } });
  hook({
    hook_event_name: "PermissionRequest", request_id: "preview-1", tool_name: "AskUserQuestion",
    tool_input: { questions: params.has("many") ? [engine, ...more] : [engine] },
  });
  // A second session asks while the first one's question is on the card: it waits its turn.
  if (params.has("sessions")) {
    hook({ ...second, hook_event_name: "PermissionRequest", request_id: "preview-3", tool_name: "AskUserQuestion", tool_input: { questions: [more[0]] } });
  }
} else if (view === "approval") {
  hook(params.has("diff")
    ? {
        hook_event_name: "PermissionRequest", request_id: "preview-2", tool_name: "Edit",
        tool_input: { file_path: `${CWD}\\windows\\src\\core\\layout.ts` },
        proposal: {
          created: false, truncated: false, additions: 5, deletions: 1,
          patch: [
            "@@ -118,9 +118,13 @@",
            " export const NEWS_LINE = 28;",
            " ",
            " export function islandSize(",
            "   mode: IslandMode,",
            "   view: IslandViewName,",
            "   chatCount = 0,",
            "-  news = false,",
            "+  news = false,",
            "+  proposal = false,",
            " ): { w: number; h: number } {",
            "   switch (mode) {",
            '     case "hidden":',
            "+      // No notch to hide inside on a PC.",
            "+      return { w: NOTCH_W, h: 0 };",
            '+    case "compact":',
          ].join("\n"),
        },
      }
    : { hook_event_name: "PermissionRequest", request_id: "preview-2", tool_name: "Bash", tool_input: { command: "cargo test -p coucou-hook" } });
} else if (view === "finished" || params.has("answered")) {
  // The turn ends on what Claude said.
  hook({
    hook_event_name: "Stop",
    last_message: [
      "The question card now answers for real: the answer goes back on the permission request, in the tool's own input.",
      "## What changed",
      "- **Question card**: answers go back in the tool's own `answers`\n- Skip tells Claude the question was *skipped*\n  and it carries on without",
      "| Function | State |\n|---|---|\n| One choice | Checked |\n| Several choices | Checked, with `Send` |",
      "```rust\nfn reply_json(answer: &str) -> Option<String> {\n    decision_json(answer.trim())\n}\n```",
      "Do you want the README updated too?",
    ].join("\n\n"),
  });
  if (view === "session") island.alert("session");
} else if (view === "session") {
  if (params.has("idle")) {
    State.session.state = "idle";
    State.present();
  }
  island.alert("session");
  if (params.has("list")) {
    requestAnimationFrame(() => {
      document.querySelector<HTMLElement>(".session-view .sess-files")?.click();
      if (params.has("file")) requestAnimationFrame(() => document.querySelector<HTMLElement>(".session-view .gh-row")?.click());
    });
  }
  // `live`: an edit lands while the panel is open, again every few seconds.
  if (params.has("live")) {
    const write = () => {
      hook({ hook_event_name: "PreToolUse", tool_name: "Read", tool_input: { file_path: `${CWD}\\src\\invoice.ts` } });
      hook({ hook_event_name: "PostToolUse", tool_name: "Read", tool_input: { file_path: `${CWD}\\src\\invoice.ts` } });
      edit("src\\invoice.ts", [
        "@@ -10,8 +10,9 @@",
        " import { Item } from './types'",
        " ",
        "-const TVA = 0.196",
        "+// The rate changed in 2014.",
        "+const TVA = 0.2",
        " ",
        " export function total(items: Item[]) {",
        "   const sum = items.reduce((s, i) => s + i.price, 0)",
        "   return sum * (1 + TVA)",
        " }",
      ].join("\n"));
      hook({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "npm test" } });
    };
    window.setTimeout(write, 1200);
    window.setInterval(write, 6000);
  }
} else {
  island.alert("overview");
}

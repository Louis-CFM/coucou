// Plays a pretend Claude Code session through the real relay, so the island,
// the relay and the socket/pipe can be tried end to end without Claude Code.
//
//   npm run fake-session               a whole session, ending on a permission request
//   npm run fake-session -- permission just the permission request
//
// Every event is piped into coucou-hook exactly as Claude Code would do it.
// Nothing is ever executed: the "command" in the permission request is only
// text for the card. For the permission request the script prints what
// Claude Code would receive — the decision JSON, or nothing at all when the
// island did not answer and the terminal would have asked instead.
//
// The relay is looked up in $COUCOU_HOOK, then $CARGO_TARGET_DIR, then
// windows/target, release build first.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const exe = process.platform === "win32" ? "coucou-hook.exe" : "coucou-hook";

function findHook() {
  if (process.env.COUCOU_HOOK) return process.env.COUCOU_HOOK;
  const targets = [process.env.CARGO_TARGET_DIR, join(root, "target")].filter(Boolean);
  for (const target of targets) {
    for (const profile of ["release", "debug"]) {
      const candidate = join(target, profile, exe);
      if (existsSync(candidate)) return candidate;
    }
  }
  return null;
}

const hook = findHook();
if (!hook) {
  console.error(`${exe} not found. Build it first: cargo build --release -p coucou-hook`);
  process.exit(1);
}

const session = `fake-${Date.now()}`;
const cwd = process.cwd();
const base = { session_id: session, cwd };

const PERMISSION = {
  hook_event_name: "PermissionRequest",
  tool_name: "Bash",
  tool_input: { command: "rm -rf ./build  # fake — nothing runs" },
};

const SESSION = [
  { hook_event_name: "SessionStart", source: "startup" },
  { hook_event_name: "UserPromptSubmit", prompt: "Tidy up the build folder" },
  { hook_event_name: "PreToolUse", tool_name: "Read", tool_input: { file_path: join(cwd, "package.json") } },
  { hook_event_name: "PostToolUse", tool_name: "Read" },
  { hook_event_name: "PreToolUse", tool_name: "Grep", tool_input: { pattern: "build" } },
  { hook_event_name: "PostToolUse", tool_name: "Grep" },
  PERMISSION,
  { hook_event_name: "Stop", message: "Build folder tidied" },
];

/** One hook run: JSON on stdin, whatever the relay prints on stdout. */
function send(event) {
  return new Promise((done) => {
    const child = spawn(hook, [event.hook_event_name], { stdio: ["pipe", "pipe", "inherit"] });
    let out = "";
    child.stdout.on("data", (chunk) => (out += chunk));
    child.on("close", (code) => done({ code, out: out.trim() }));
    child.stdin.end(JSON.stringify({ ...base, ...event }));
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const events = process.argv[2] === "permission" ? [PERMISSION] : SESSION;
console.log(`relay: ${hook}\nsession: ${session}\n`);

for (const event of events) {
  const name = event.hook_event_name;
  if (name === "PermissionRequest") {
    console.log(`${name}: waiting for Allow / Deny on the island…`);
  }
  const { code, out } = await send(event);
  if (name === "PermissionRequest") {
    console.log(out ? `  Claude Code would get: ${out}` : "  no answer — Claude Code would ask in the terminal");
  } else {
    console.log(`${name}${code === 0 ? "" : ` (exit ${code})`}`);
  }
  await sleep(900);
}

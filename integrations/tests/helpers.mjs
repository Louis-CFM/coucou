import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const context = id => ({ cwd: "/project/example", sessionManager: { getSessionId: () => id } });

export function register(factory) {
  const handlers = new Map();
  factory({ on: (name, handler) => handlers.set(name, handler) });
  return async (name, event = {}, ctx = context("one")) => handlers.get(name)?.(event, ctx);
}

export async function fixture(t) {
  const dir = await mkdtemp(join(tmpdir(), "coucou-extension-"));
  const previous = { ...process.env };
  t.after(async () => {
    process.env = previous;
    await rm(dir, { recursive: true, force: true });
  });
  const script = join(dir, "relay.mjs");
  const hook = join(dir, "hook with spaces");
  const log = join(dir, "events.jsonl");
  await writeFile(script, `
import { appendFileSync } from 'node:fs';
let line = '';
for await (const chunk of process.stdin) line += chunk;
if (process.env.COUCOU_TEST_STALL) setInterval(() => {}, 1000);
else appendFileSync(process.env.COUCOU_TEST_LOG, JSON.stringify({
  args: process.argv.slice(2), payload: JSON.parse(line)
}) + '\\n');
`);
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  await writeFile(hook, `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(script)} "$@"\n`, { mode: 0o700 });
  process.env.COUCOU_HOOK_PATH = hook;
  process.env.COUCOU_TEST_LOG = log;
  delete process.env.COUCOU_TEST_STALL;
  return {
    dir,
    hook,
    async records() {
      try { return (await readFile(log, "utf8")).trim().split("\n").filter(Boolean).map(JSON.parse); }
      catch (error) { if (error.code === "ENOENT") return []; throw error; }
    },
  };
}

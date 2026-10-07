import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const output = await mkdtemp(join(tmpdir(), "coucou-memory-status-"));
try {
  const tsc = resolve("node_modules/typescript/bin/tsc");
  const source = resolve("src/core/memory-status.ts");
  const compile = spawnSync(process.execPath, [tsc, source, "--target", "ES2022", "--module", "ES2022", "--moduleResolution", "bundler", "--strict", "--outDir", output], { encoding: "utf8" });
  assert.equal(compile.status, 0, compile.stderr || compile.stdout);
  const { PendingMemoryStatuses, applyPendingMemoryStatus, resetMemoryStatuses } = await import(pathToFileURL(join(output, "memory-status.js")));

  const pending = new PendingMemoryStatuses(128);
  pending.set("saved-before-insert", "saving");
  pending.set("saved-before-insert", "saved");
  assert.equal(applyPendingMemoryStatus({ turnId: "saved-before-insert" }, pending).memoryStatus, "saved");
  assert.equal(pending.size, 0);

  pending.set("failed-before-insert", "notSaved");
  assert.equal(applyPendingMemoryStatus({ turnId: "failed-before-insert" }, pending).memoryStatus, "notSaved");

  for (let index = 0; index <= 128; index += 1) pending.set(`turn-${index}`, "saving");
  assert.equal(pending.size, 128);
  assert.equal(pending.take("turn-0"), undefined);
  assert.equal(pending.take("turn-128"), "saving");

  pending.set("reset-me", "saved");
  resetMemoryStatuses(pending);
  assert.equal(pending.size, 0);
  assert.equal(applyPendingMemoryStatus({ turnId: "reset-me" }, pending).memoryStatus, undefined);

  const chatSync = await readFile(resolve("src/core/chat-sync.ts"), "utf8");
  const resetBody = chatSync.match(/export function resetChat\(\) \{([\s\S]*?)\n\}/)?.[1] ?? "";
  assert.match(resetBody, /State\.chatHistory = \[\]/);
  assert.match(resetBody, /resetMemoryStatuses\(State\.pendingMemoryStatuses\)/);
  assert.match(resetBody, /Bridge\.chatReset\(\)/);
  assert.match(resetBody, /publishChat\(\)/);
  assert.match(chatSync, /if \(history\.length === 0\) resetMemoryStatuses\(State\.pendingMemoryStatuses\)/);

  const island = await readFile(resolve("src/island/island.ts"), "utf8");
  const swallowBody = island.match(/private swallow\(path: string\) \{([\s\S]*?)\n  \}/)?.[1] ?? "";
  assert.match(swallowBody, /resetChat\(\)/);
  assert.doesNotMatch(swallowBody, /State\.chatHistory = \[\]/);
  console.log("memory-status: PASS");
} finally {
  await rm(output, { recursive: true, force: true });
}

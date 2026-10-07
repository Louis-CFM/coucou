import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const read = (path) => readFile(resolve(path), "utf8");
const [html, manager, settings, chat, bridge, vite, capability] = await Promise.all([
  read("memory.html"),
  read("src/memory/main.ts"),
  read("src/settings/main.ts"),
  read("src/views/chat.ts"),
  read("src/core/bridge.ts"),
  read("vite.config.ts"),
  read("src-tauri/capabilities/default.json"),
]);

assert.match(html, /<main[^>]+id="memory-root"/);
assert.match(vite, /memory:\s*resolve\(__dirname, "memory\.html"\)/);
assert.ok(JSON.parse(capability).windows.includes("memory"));

for (const command of ["memoryList", "memoryGet", "memorySafeDetail", "memoryUpdate", "memoryRetire", "memoryRestore", "memoryBulkRetire", "memoryExport"]) {
  assert.match(bridge, new RegExp(`"${command}"`), `bridge missing ${command}`);
}
assert.match(bridge, /hindsightTestConnection/);
assert.match(bridge, /memorySaveExport/);

for (const control of ["memory-query", "memory-state", "memory-fact-type", "memory-start-date", "memory-end-date", "memory-time-field", "memory-platform", "memory-retention", "memory-source"]) {
  assert.match(manager, new RegExp(control), `manager missing ${control}`);
}
assert.match(manager, /requestGeneration/);
assert.match(manager, /memoryError\(error\)\.kind === "cancelled"/);
assert.doesNotMatch(manager, /includes\("superseded"\)/);
assert.match(manager, /showModal\(\)/);
assert.match(manager, /bulk-confirm-heading/);
assert.match(manager, /expectedUpdatedAt/);
assert.match(manager, /saveEdit\(update, true\)/);
assert.match(manager, /Bridge\.memorySaveExport/);
assert.match(manager, /failed\.map/);

assert.match(settings, /Hindsight memory/);
assert.match(settings, /autocomplete:\s*"new-password"/);
assert.match(settings, /hindsightBearerTokenPresent/);
assert.match(settings, /hindsightBearerTokenSet/);
assert.match(settings, /hindsightBearerTokenDelete/);
assert.match(settings, /hindsightTestConnection/);
assert.doesNotMatch(settings, /field\.value\s*=\s*.*token/i);

assert.match(chat, /aria-pressed/);
assert.match(chat, /Remember turn/);
assert.match(chat, /Remember selection/);
assert.match(chat, /window\.getSelection\(\)/);
assert.match(chat, /selection\.rangeCount/);
assert.match(chat, /isComposing/);
assert.match(chat, /Bridge\.rememberTurn/);
assert.match(chat, /Bridge\.rememberSelection/);
assert.match(chat, /Forget/);
assert.match(chat, /Bridge\.openMemoryWindow/);

console.log("memory-ui: PASS");

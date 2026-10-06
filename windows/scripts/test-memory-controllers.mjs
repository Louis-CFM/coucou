import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const output = await mkdtemp(join(tmpdir(), "coucou-memory-controllers-"));
try {
  const tsc = resolve("node_modules/typescript/bin/tsc");
  const sources = ["src/memory/controllers.ts", "src/memory/baseline-contracts.ts", "src/settings/save-queue.ts", "src/views/memory-selection.ts", "src/core/questions.ts", "src/core/state.ts"];
  const compile = spawnSync(process.execPath, [tsc, ...sources, "--target", "ES2022", "--module", "ES2022", "--moduleResolution", "bundler", "--strict", "--outDir", output], { encoding: "utf8" });
  assert.equal(compile.status, 0, compile.stderr || compile.stdout);
  const controllers = await import(pathToFileURL(join(output, "memory/controllers.js")));
  const questions = await import(pathToFileURL(join(output, "core/questions.js")));
  const { SettingsSaveQueue } = await import(pathToFileURL(join(output, "settings/save-queue.js")));
  const selection = await import(pathToFileURL(join(output, "views/memory-selection.js")));

  const applied = { filter: { state: "valid", query: "old" }, limit: 25, offset: 0 };
  const snapshot = controllers.snapshotBulkScope(applied, 42, "https://HOST.example:443/Hindsight/", "tenant-a", "bank-a");
  applied.filter.query = "new";
  assert.equal(snapshot.request.filter.query, "old");
  assert.equal(snapshot.total, 42);
  assert.match(snapshot.fingerprint, /tenant-a/);
  assert.equal(controllers.canBulkRetire({ filter: { state: "invalidated" }, limit: 25, offset: 0 }), false);
  assert.equal(controllers.sameScope(snapshot, snapshot.fingerprint), true);
  assert.equal(controllers.sameScope(snapshot, "changed"), false);
  assert.equal(snapshot.endpoint, "https://host.example/Hindsight");
  assert.notEqual(controllers.normalizeEndpoint("https://host.example/Hindsight"), controllers.normalizeEndpoint("https://host.example/hindsight"));
  assert.deepEqual(controllers.confirmedScopeArgs(snapshot), { scope: { request: snapshot.request, endpoint: "https://host.example/Hindsight", tenant: "tenant-a", bank: "bank-a", fingerprint: snapshot.fingerprint } });

  const readyOrder = [];
  let replayHandler;
  await controllers.bootstrapMemorySearch(async (handler) => { readyOrder.push("listen:start"); await Promise.resolve(); replayHandler = handler; readyOrder.push("listen:ready"); return () => {}; }, async () => { readyOrder.push("ready"); replayHandler({ query: "replayed", documentIds: ["doc-b", "doc-a", "doc-b"] }); });
  assert.deepEqual(readyOrder, ["listen:start", "listen:ready", "ready"]);

  const presentation = controllers.normalizeMemoryPresentation({ query: "fallback words", documentIds: ["doc-b", "doc-a", "doc-b", " "] });
  assert.deepEqual(presentation, { query: undefined, documentIds: ["doc-b", "doc-a"] });
  assert.deepEqual(controllers.normalizeMemoryPresentation({ query: "fallback words", documentIds: [] }), { query: "fallback words", documentIds: [] });
  const merged = controllers.mergeDocumentPages([
    { items: [{ id: "b" }, { id: "a" }], total: 2, limit: 25, offset: 0 },
    { items: [{ id: "a" }, { id: "c" }], total: 2, limit: 25, offset: 0 },
  ], 25, 0);
  assert.deepEqual(merged.items.map((item) => item.id), ["b", "a", "c"]);
  assert.equal(merged.total, 3);
  const pageCalls = [];
  const complete = await controllers.loadCompleteDocumentUnion(["doc-b", "doc-a"], 2, async (documentId, limit, offset) => {
    pageCalls.push(`${documentId}:${offset}`);
    const pages = {
      "doc-b:0": [{ id: "b" }, { id: "a" }],
      "doc-b:2": [{ id: "a" }, { id: "c" }],
      "doc-b:4": [],
      "doc-a:0": [{ id: "c" }, { id: "d" }],
      "doc-a:2": [{ id: "e" }],
    };
    return { items: pages[`${documentId}:${offset}`], total: 99, limit, offset };
  });
  assert.deepEqual(pageCalls, ["doc-b:0", "doc-b:2", "doc-b:4", "doc-a:0", "doc-a:2"]);
  assert.deepEqual(complete.map((item) => item.id), ["b", "a", "c", "d", "e"]);
  assert.deepEqual(controllers.sliceDocumentUnion(complete, 2, 2).items.map((item) => item.id), ["c", "d"]);
  await assert.rejects(() => controllers.loadCompleteDocumentUnion(["doc"], 2, async () => ({ items: [{ id: "a" }, { id: "b" }], total: 2, limit: 2, offset: 0 })), /did not advance/);
  await assert.rejects(() => controllers.loadCompleteDocumentUnion(["doc"], 1, async (_documentId, limit, offset) => ({ items: [{ id: `m${offset}` }], total: 999, limit, offset }), 3), /maximum page count/);

  const prepared = controllers.snapshotForgetConfirmation({ turnId: "turn-1", generation: 7, endpoint: "https://host/Hindsight", tenant: "tenant-a", bank: "bank-a", knownIds: ["m2", "m1"], documentIds: ["doc-b", "doc-a", "doc-b"], artifactFingerprint: "fp" });
  prepared.documentIds.push("tamper");
  const immutableArgs = controllers.forgetTurnArgs(controllers.snapshotForgetConfirmation({ turnId: "turn-1", generation: 7, endpoint: "https://host/Hindsight", tenant: "tenant-a", bank: "bank-a", knownIds: ["m2", "m1"], documentIds: ["doc-b", "doc-a", "doc-b"], artifactFingerprint: "fp" }));
  assert.equal(immutableArgs.confirmation.turnId, "turn-1");
  assert.deepEqual(immutableArgs.confirmation.knownIds, ["m2", "m1"]);
  assert.equal(immutableArgs.confirmation.generation, 7);
  const forgetCopy = controllers.forgetConfirmationCopy(controllers.snapshotForgetConfirmation({ turnId: "turn-1", generation: 7, endpoint: "https://host/Hindsight", tenant: "tenant-a", bank: "bank-a", knownIds: ["m2", "m1", "m3"], documentIds: ["doc-b", "doc-a"], artifactFingerprint: "fp" }));
  for (const exact of ["Turn ID: turn-1", "Tenant: tenant-a", "Bank: bank-a", "Known remote IDs: 3", "Document IDs: doc-b, doc-a"]) assert.equal(forgetCopy.includes(exact), true);

  const order = [];
  let releaseFirst;
  const firstGate = new Promise((resolve) => { releaseFirst = resolve; });
  const queue = new SettingsSaveQueue(async (value) => { order.push(`start:${value.revision}`); if (value.revision === 1) await firstGate; order.push(`end:${value.revision}`); });
  queue.schedule({ revision: 1, enabled: false });
  queue.schedule({ revision: 2, enabled: true });
  queue.schedule({ revision: 3, enabled: false });
  await Promise.resolve();
  assert.deepEqual(order, ["start:1"]);
  releaseFirst();
  await queue.idle();
  assert.deepEqual(order, ["start:1", "end:1", "start:3", "end:3"]);
  assert.equal(queue.revision, 3);
  queue.replaceCurrent({ revision: 4, enabled: true });
  assert.equal(queue.revision, 4);

  const recovery = [];
  let attempts = 0;
  const recovering = new SettingsSaveQueue(async (value) => { attempts += 1; recovery.push(value.revision); if (attempts === 1) throw new Error("disk full"); });
  recovering.schedule({ revision: 1, enabled: false });
  recovering.schedule({ revision: 2, enabled: true });
  await assert.rejects(() => recovering.idle(), /disk full/);
  recovering.schedule({ revision: 3, enabled: false });
  await recovering.idle();
  assert.deepEqual(recovery, [1, 2, 3]);
  assert.equal(recovering.lastError, null);
  assert.equal(recovering.maxConcurrent, 1);

  assert.notEqual(controllers.chatRenderKey([{ id: 1, memoryStatus: "saving" }]), controllers.chatRenderKey([{ id: 1, memoryStatus: "saved" }]));
  assert.equal(controllers.memoryStatusText("saving"), "Saving memory…");
  assert.equal(controllers.memoryStatusText("saved"), "Memory saved");
  assert.equal(controllers.memoryStatusText("notSaved"), "Memory not saved");
  assert.equal(questions.sameText("  Which MODEL? ", "which model?"), true);
  assert.deepEqual(questions.liveLabels(["two", "one"], ["one", "two"]), ["one", "two"]);
  assert.equal(questions.liveLabels(["two", "missing"], ["one", "two"]), null);
  const questionCarrier = { questions: [{ question: "q", multiSelect: false, options: [{ label: "one" }] }], picks: [["one"]], step: 0 };
  assert.equal(questions.currentStep(questionCarrier), 0);
  assert.equal(questions.allAnswered(questionCarrier), true);

  const detail = new controllers.DetailGuard();
  const old = detail.begin("old");
  const current = detail.begin("new");
  assert.equal(detail.accept(old, "old"), false);
  assert.equal(detail.accept(current, "old"), false);
  assert.equal(detail.accept(current, "new"), true);

  const failed = controllers.dialogActionState();
  let rejectOverwrite;
  const overwrite = new Promise((_, reject) => { rejectOverwrite = reject; });
  const actionPromise = controllers.runDialogAction(failed, () => overwrite);
  assert.equal(failed.busy, true);
  rejectOverwrite(new Error("network down"));
  await assert.rejects(() => actionPromise, /network down/);
  assert.equal(failed.busy, false);
  assert.equal(failed.open, true);
  assert.equal(failed.error, "network down");
  const succeeded = controllers.dialogActionState();
  await controllers.runDialogAction(succeeded, async () => {});
  assert.equal(succeeded.open, false);

  assert.deepEqual(controllers.validateMemoryEdit({ text: "", occurredStart: "" }), { field: "text", message: "Memory text is required." });
  assert.equal(controllers.validateMemoryEdit({ text: "ok", occurredStart: "not-a-date" }).field, "occurredStart");
  assert.equal(controllers.validateMemoryEdit({ text: "ok", occurredStart: "2026-02-30T10:00:00Z" }).field, "occurredStart");
  assert.equal(controllers.validateMemoryEdit({ text: "ok", occurredStart: "2026-10-02T25:00:00Z" }).field, "occurredStart");
  assert.equal(controllers.validateMemoryEdit({ text: "ok", occurredStart: "2026-10-02T10:00:00Z" }), null);
  const validity = { invalid: true, described: true, message: "bad" };
  controllers.applyValidationResult(validity, null);
  assert.deepEqual(validity, { invalid: false, described: false, message: "" });

  const staleEvents = [];
  const guarded = new controllers.DetailGuard();
  const oldGeneration = guarded.begin("old");
  const newGeneration = guarded.begin("new");
  controllers.setDetailOutcome(guarded, newGeneration, "new", () => staleEvents.push("new:success"));
  controllers.setDetailOutcome(guarded, oldGeneration, "old", () => staleEvents.push("old:error"));
  assert.deepEqual(staleEvents, ["new:success"]);

  assert.deepEqual(selection.utf8Span("tea tea", 4, 7), { text: "tea", start: 4, end: 7 });
  assert.deepEqual(selection.utf8Span("A☕B", 1, 2), { text: "☕", start: 1, end: 4 });
  assert.equal(selection.selectionWithinBubble({ anchorBubble: "a", focusBubble: "b" }), false);
  assert.equal(selection.selectionWithinBubble({ anchorBubble: "a", focusBubble: "a" }), true);

  const persistent = controllers.partialFailureAfterRefresh({ requested: 3, succeeded: ["a"], failed: [{ id: "b", kind: "conflict", message: "conflict" }], refresh: true });
  const calls = [];
  await controllers.refreshThenReport(async () => { calls.push("refresh"); }, (result) => calls.push(`report:${result.failed[0].id}:${result.refresh}`), persistent);
  assert.deepEqual(calls, ["refresh", "report:b:true"]);

  const retirement = controllers.snapshotIndividualRetirement({ id: "m1", text: "plain <b>text</b>", updatedAt: "v1" }, "https://HOST.example:443/Hindsight/", "tenant-a", "bank-a");
  assert.deepEqual(retirement, { id: "m1", text: "plain <b>text</b>", updatedAt: "v1", endpoint: "https://host.example/Hindsight", tenant: "tenant-a", bank: "bank-a" });
  assert.equal(controllers.individualRetirementCopy(retirement).includes("Retire 1 memory"), true);
  assert.equal(controllers.individualRetirementCopy(retirement).includes("Tenant: tenant-a"), true);
  assert.equal(controllers.individualRetirementCopy(retirement).includes("Bank: bank-a"), true);
  assert.equal(controllers.individualRetirementCopy(retirement).includes("reversible"), true);

  const baseline = await import(pathToFileURL(join(output, "memory/baseline-contracts.js")));
  assert.equal(baseline.ROBOT_DEFAULT, "Ctrl+Alt+R");
  assert.equal(baseline.hermesAutoAdvance({ multiSelect: false }, ["One"], 0, 2), true);
  assert.deepEqual(baseline.hermesExpiredEffects(), { log: true, sound: "blip", returnAfterDelay: true });

  console.log("memory-controllers: PASS");
} finally {
  await rm(output, { recursive: true, force: true });
}

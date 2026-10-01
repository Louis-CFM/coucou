#!/usr/bin/env node
// Bounded, disposable smoke test for the installed Codex desktop runtime's
// trusted Coucou PermissionRequest hook. This launches a separate app-server;
// it never attaches to or claims to test an existing desktop chat.
//
// Usage: node windows/scripts/verify-codex-runtime-hooks.mjs allow|deny|closed
// allow/deny require the running Coucou CDP endpoint (default localhost:9333).
// closed requires Coucou to be closed and verifies native app-server fallback.

import { spawn, execFileSync } from "node:child_process";
import { createInterface } from "node:readline";
import { mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const scenario = process.argv[2];
if (!["allow", "deny", "closed"].includes(scenario)) {
  console.error("Usage: node windows/scripts/verify-codex-runtime-hooks.mjs allow|deny|closed");
  process.exit(2);
}

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const runtimeRoot = resolve(repoRoot, "_prive/desktop-live/runtime-approval");
const cdpBase = process.env.COUCOU_CDP_URL || "http://127.0.0.1:9333";
const cdpTimeoutMs = 90_000;
const turnTimeoutMs = 150_000;
const token = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 9)}`;
const markerName = `marker-${token}.txt`;
const markerContents = "CODEX_COUCOU_SMOKE_OK";
await mkdir(runtimeRoot, { recursive: true });
const workspaceRoot = await mkdtemp(join(runtimeRoot, `${scenario}-`));
const workspace = join(workspaceRoot, "workspace");
const markerPath = join(workspaceRoot, markerName);
await mkdir(workspace, { recursive: true });

let cli;
let cliVersion;
let child;
let rpc;
let cdp;
let threadId;
let turnId;
let turnDone = false;
let turnFailure = false;
let hookDecisionUi = false;
let hookDecision = null;
let nativeApprovalFallbacks = 0;
let serverRequests = 0;
let modelId = null;
let result = "failed";
let markerWritten = false;
let phase = "startup";
let reportExtra = {};

function out(extra = {}) {
  console.log(JSON.stringify({
    runtime: "installed-desktop-cli-separate-ephemeral-app-server",
    version: cliVersion,
    scenario,
    model: modelId,
    coucouApprovalUi: hookDecisionUi,
    nativeApprovalFallbacks,
    markerWritten,
    result,
    ...extra,
  }));
}

function cleanEnv() {
  const env = { ...process.env };
  // Do not inherit this desktop task's private app-server/thread routing.
  for (const key of [
    "CODEX_APP_TOOLS_PIPE_PATH", "CODEX_THREAD_ID", "CODEX_SESSION_ID",
    "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_TASK_WORKSPACE_VERIFYING_IDENTITY",
    "OPENAI_API_KEY", "OPENAI_ACCESS_TOKEN", "ANTHROPIC_API_KEY", "CODEX_API_KEY",
  ]) delete env[key];
  env.CODEX_CLI_PATH = cli;
  return env;
}

function deferred() {
  let resolvePromise;
  const promise = new Promise(resolve => { resolvePromise = resolve; });
  return { promise, resolve: resolvePromise };
}

async function settleWithin(promise, timeoutMs) {
  let timer;
  try {
    return await Promise.race([
      promise.then(() => true),
      new Promise(resolvePromise => {
        timer = setTimeout(() => resolvePromise(false), timeoutMs);
        timer.unref?.();
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function waitForExit(proc, timeoutMs) {
  if (!proc || proc.exitCode !== null || proc.signalCode !== null) return true;
  return settleWithin(new Promise(resolvePromise => proc.once("exit", () => resolvePromise(true))), timeoutMs);
}

async function removeDisposableDirectory(target) {
  const base = `${resolve(runtimeRoot)}${sep}`.toLowerCase();
  const candidate = resolve(target).toLowerCase();
  if (!candidate.startsWith(base)) throw new Error("refusing cleanup outside disposable smoke-test directory");
  let lastError;
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      await rm(target, { recursive: true, force: true, maxRetries: 2, retryDelay: 100 });
      return;
    } catch (error) {
      lastError = error;
      if (attempt < 4) await delay([150, 300, 600, 1_000][attempt]);
    }
  }
  throw lastError || new Error("disposable directory cleanup failed");
}

class AppServer {
  constructor(proc) {
    this.proc = proc;
    this.nextId = 1;
    this.pending = new Map();
    this.events = new Map();
    this.closed = false;
    this.lines = createInterface({ input: proc.stdout, crlfDelay: Infinity });
    this.lines.on("line", line => this.onLine(line));
    proc.on("exit", () => {
      this.closed = true;
      for (const pending of this.pending.values()) pending.reject(new Error("runtime process exited"));
      this.pending.clear();
    });
  }
  send(message) {
    if (this.closed || !this.proc.stdin.writable) throw new Error("runtime process unavailable");
    this.proc.stdin.write(`${JSON.stringify(message)}\n`);
  }
  notify(method, params = {}) { this.send({ method, params }); }
  request(method, params = {}, timeoutMs = 30_000) {
    const id = this.nextId++;
    return new Promise((resolvePromise, rejectPromise) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        rejectPromise(new Error(`runtime request timed out: ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: value => { clearTimeout(timeout); resolvePromise(value); },
        reject: error => { clearTimeout(timeout); rejectPromise(error); },
      });
      try { this.send({ id, method, params }); }
      catch (error) { clearTimeout(timeout); this.pending.delete(id); rejectPromise(error); }
    });
  }
  on(method, fn) {
    if (!this.events.has(method)) this.events.set(method, new Set());
    this.events.get(method).add(fn);
    return () => this.events.get(method)?.delete(fn);
  }
  onLine(line) {
    if (line.length > 1_000_000) { this.closed = true; return; }
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (typeof message.method === "string" && Object.hasOwn(message, "id")) {
      serverRequests++;
      if (message.method.endsWith("/requestApproval")) {
        nativeApprovalFallbacks++;
        this.send({ id: message.id, result: { decision: "decline" } });
      } else {
        // Never allow unknown server-initiated operations in this smoke test.
        this.send({ id: message.id, error: { code: -32601, message: "Not supported by approval smoke test" } });
      }
      return;
    }
    if (Object.hasOwn(message, "id")) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(`runtime RPC error ${message.error.code ?? "unknown"}`));
      else pending.resolve(message.result);
      return;
    }
    for (const fn of this.events.get(message.method) || []) fn(message.params || {});
  }
}

class DevTools {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.ready = new Promise((resolvePromise, rejectPromise) => {
      this.ws.addEventListener("open", resolvePromise, { once: true });
      this.ws.addEventListener("error", () => rejectPromise(new Error("Coucou DevTools connection failed")), { once: true });
    });
    this.ws.addEventListener("message", event => {
      let message;
      try { message = JSON.parse(event.data); } catch { return; }
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error("Coucou DevTools command failed"));
      else pending.resolve(message.result);
    });
  }
  async evaluate(expression) {
    await this.ready;
    const id = this.nextId++;
    return new Promise((resolvePromise, rejectPromise) => {
      const timeout = setTimeout(() => { this.pending.delete(id); rejectPromise(new Error("Coucou DevTools timed out")); }, 3_000);
      this.pending.set(id, {
        resolve: value => { clearTimeout(timeout); resolvePromise(value); },
        reject: error => { clearTimeout(timeout); rejectPromise(error); },
      });
      this.ws.send(JSON.stringify({ id, method: "Runtime.evaluate", params: { expression, awaitPromise: true, returnByValue: true } }));
    });
  }
  close() { try { this.ws.close(); } catch {} }
}

async function getCoucouTarget() {
  const response = await fetch(`${cdpBase.replace(/\/$/, "")}/json/list`, { signal: AbortSignal.timeout(2_000) });
  if (!response.ok) throw new Error("Coucou DevTools endpoint did not respond");
  const targets = await response.json();
  const target = targets.find(item => item.type === "page" && item.title === "Coucou" && item.webSocketDebuggerUrl);
  if (!target) throw new Error("Coucou page was not found on the configured DevTools endpoint");
  return new DevTools(target.webSocketDebuggerUrl);
}

async function approvalCardVisible() {
  const code = JSON.stringify(markerName);
  const expression = `(() => [...document.querySelectorAll('.view')].some(v => { const c=v.querySelector('.code'); return c && c.textContent.includes(${code}) && [...v.querySelectorAll('button')].some(b => ['Allow','Deny'].includes((b.querySelector('span')?.textContent||'').trim())); }))()`;
  const response = await cdp.evaluate(expression);
  return Boolean(response?.result?.value);
}

async function clickDecision(decision) {
  const code = JSON.stringify(markerName);
  const label = JSON.stringify(decision === "allow" ? "Allow" : "Deny");
  const expression = `(() => { const v=[...document.querySelectorAll('.view')].find(v => {const c=v.querySelector('.code'); return c && c.textContent.includes(${code});}); if(!v) return false; const b=[...v.querySelectorAll('button')].find(b => (b.querySelector('span')?.textContent||'').trim()===${label}); if(!b) return false; b.click(); return true; })()`;
  const response = await cdp.evaluate(expression);
  return Boolean(response?.result?.value);
}

async function waitForApprovalUi(decision) {
  const until = Date.now() + cdpTimeoutMs;
  while (Date.now() < until) {
    if (nativeApprovalFallbacks > 0) return false;
    if (await approvalCardVisible()) {
      hookDecisionUi = await clickDecision(decision);
      if (hookDecisionUi) { hookDecision = decision; return true; }
    }
    await delay(300);
  }
  return false;
}

async function cleanup() {
  if (rpc && threadId && turnId && !turnDone) {
    try { await rpc.request("turn/interrupt", { threadId, turnId }, 2_000); } catch {}
  }
  if (rpc) { try { rpc.notify("shutdown", {}); } catch {} }
  if (child && child.exitCode === null && child.signalCode === null) {
    try { child.stdin.end(); } catch {}
    if (!await waitForExit(child, 1_000)) {
      try { child.kill(); } catch {}
      if (!await waitForExit(child, 2_000)) {
        try { child.kill("SIGKILL"); } catch {}
        await waitForExit(child, 1_000);
      }
    }
  }
  if (rpc) rpc.lines.close();
  if (child?.stdin && !child.stdin.destroyed) child.stdin.destroy();
  if (child?.stdout && !child.stdout.destroyed) child.stdout.destroy();
  if (child?.stderr && !child.stderr.destroyed) child.stderr.destroy();
  if (cdp) cdp.close();
  await removeDisposableDirectory(workspaceRoot);
  if (child && child.exitCode === null && child.signalCode === null) {
    throw new Error("separate app-server child did not exit after bounded termination");
  }
}

try {
  phase = "runtime-version";
  if (process.platform !== "win32") throw new Error("this harness is for the Windows desktop runtime");
  cli = process.env.CODEX_CLI_PATH;
  if (!cli) throw new Error("CODEX_CLI_PATH must point to the installed desktop runtime");
  cliVersion = execFileSync(cli, ["--version"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 5_000 })
    .trim().match(/\b\d+\.\d+\.\d+\b/)?.[0] || "unknown";

  if (scenario === "closed") {
    try {
      const response = await fetch(`${cdpBase.replace(/\/$/, "")}/json/version`, { signal: AbortSignal.timeout(800) });
      if (response.ok) throw new Error("close Coucou before running the closed-fallback scenario");
    } catch (error) {
      if (error.message === "close Coucou before running the closed-fallback scenario") throw error;
    }
  } else {
    phase = "coucou-devtools-connect";
    cdp = await getCoucouTarget();
  }

  phase = "app-server-start";
  child = spawn(cli, [
    "app-server",
    "-c", 'forced_login_method="chatgpt"',
    "-c", "analytics.enabled=false",
    "--listen", "stdio://",
  ], {
    cwd: workspace,
    env: cleanEnv(),
    stdio: ["pipe", "pipe", "ignore"],
    windowsHide: true,
  });
  child.on("error", () => {});
  rpc = new AppServer(child);
  phase = "app-server-initialize";
  await rpc.request("initialize", { clientInfo: { name: "coucou-runtime-approval-smoke", title: "Coucou approval smoke test", version: "1" } });
  rpc.notify("initialized", {});

  phase = "model-list";
  const catalog = await rpc.request("model/list", { includeHidden: false, limit: 100 });
  const selected = catalog.data?.find(item => item.model === "gpt-6-luna" || item.id === "gpt-6-luna");
  if (!selected) throw new Error("installed runtime returned no selectable model");
  modelId = selected.model;

  phase = "ephemeral-thread-start";
  const started = await rpc.request("thread/start", {
    model: modelId,
    cwd: workspace,
    sandbox: "workspace-write",
    approvalPolicy: "on-request",
    ephemeral: true,
    serviceName: "coucou-approval-smoke",
  });
  threadId = started.thread?.id || started.thread?.threadId;
  if (!threadId) throw new Error("runtime did not return an ephemeral test thread");

  const command = `node -e "require('node:fs').writeFileSync('../${markerName}','${markerContents}')"`;
  const prompt = `For this one-action approval smoke test, run exactly this single shell command and do nothing else: ${command}\nThe marker target is outside the writable workspace, so request the sandbox permission required for this exact command. Do not use any other tools, read files, run additional commands, or retry. If execution is denied, stop immediately.`;
  const doneSignal = deferred();
  const offDone = rpc.on("turn/completed", params => {
    if (!turnId || params.turn?.id === turnId || params.turnId === turnId) {
      turnDone = true;
      turnFailure = params.turn?.status === "failed" || params.status === "failed";
      doneSignal.resolve(true);
    }
  });
  phase = "turn-start";
  const startedTurn = await rpc.request("turn/start", {
    threadId,
    input: [{ type: "text", text: prompt }],
    effort: selected.supportedReasoningEfforts?.some(item => item.reasoningEffort === "xhigh") ? "xhigh" : undefined,
  }, 20_000);
  turnId = startedTurn.turn?.id || startedTurn.turn?.turnId;

  let uiResult = false;
  phase = scenario === "closed" ? "native-fallback-wait" : "coucou-hook-approval-wait";
  if (scenario === "allow" || scenario === "deny") uiResult = await waitForApprovalUi(scenario);
  else {
    const until = Date.now() + turnTimeoutMs;
    while (Date.now() < until && nativeApprovalFallbacks === 0 && !turnDone) await delay(200);
  }
  if (scenario === "closed" && nativeApprovalFallbacks > 0) {
    await settleWithin(doneSignal.promise, 20_000);
    result = turnDone && !turnFailure ? "native-fallback-declined" : "native-fallback-observed-turn-incomplete";
  } else if ((scenario === "allow" || scenario === "deny") && uiResult) {
    await settleWithin(doneSignal.promise, turnTimeoutMs);
    if (!turnDone && turnId) {
      try { await rpc.request("turn/interrupt", { threadId, turnId }, 2_000); } catch {}
    }
    try { markerWritten = (await readFile(markerPath, "utf8")) === markerContents; } catch {}
    result = scenario === "allow"
      ? (markerWritten && turnDone && !turnFailure ? "allow-passed" : "allow-ui-observed-marker-missing-or-turn-failed")
      : (!markerWritten && turnDone && !turnFailure ? "deny-passed" : "deny-marker-or-turn-check-failed");
  } else {
    result = scenario === "closed" ? "native-fallback-not-observed" : "coucou-hook-ui-not-observed";
  }
  phase = "verify-result";
  offDone();
  reportExtra = { approvalDecision: hookDecision, turnCompleted: turnDone, turnFailed: turnFailure, serverRequests };
} catch (error) {
  result = "harness-error";
} finally {
  let cleanupComplete = true;
  try { await cleanup(); } catch {
    cleanupComplete = false;
    result = "cleanup-failed";
    process.exitCode = 1;
    console.error("Smoke harness cleanup failed; inspect only the generated disposable test directory.");
  }
  out({ ...reportExtra, phase, cleanupComplete });
  if (!["allow-passed", "deny-passed", "native-fallback-declined"].includes(result)) process.exitCode = 1;
}

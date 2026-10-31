// Exercise the real pill entry point through the existing DOM and Tauri fakes.
// Native window positioning and the Windows startup flash need a real desktop.
import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { installFakeDom } from "./fakedom.mjs";
import { calls, emit, internals, sent } from "./tauri.mjs";

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.endsWith(".css")) {
      return { url: new URL(specifier, context.parentURL).href, shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true };
    return nextLoad(url, context);
  },
});

const idle = {
  phase: "idle", edge: "bottom", key: "right_ctrl", noteStartedAt: null,
  announcement: null, enabled: false, voice: null,
};
const invoke = internals.invoke;
let root;
let loads = 0;

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  const dom = installFakeDom();
  root = dom.root();
  root.querySelectorAll = (selector) => root.find(selector);
  document.getElementById = (id) => id === "pill" ? root : null;
  document.addEventListener = () => {};
  document.documentElement = { dataset: {} };
  const createElement = document.createElement;
  document.createElement = (tag) => {
    const element = createElement(tag);
    if (tag === "canvas") element.getContext = () => ({ measureText: (text) => ({ width: text.length * 7 }) });
    return element;
  };
  // Painting is outside this test: keep animation frames queued, like a webview
  // awaiting its next frame, rather than recursing through the animation loop.
  requestAnimationFrame = () => 1;
  window.innerWidth = 320;
  window.innerHeight = 120;
  calls.length = 0;
});

afterEach(() => {
  mock.timers.runAll();
  mock.timers.reset();
});

async function boot(context, state = idle) {
  context.mock.method(internals, "invoke", async (cmd, args) => {
    if (cmd === "boot") return { settings: { language: "en" } };
    if (cmd === "flow_status") return { platform: "windows" };
    if (cmd === "pill_state") return { ...state };
    return invoke(cmd, args);
  });
  // Each boot gets fresh entry-point state; the shared bridge remains real.
  const url = new URL("../src/pill/main.ts", import.meta.url);
  url.searchParams.set("boot", String(++loads));
  await import(url.href);
  await new Promise((resolve) => setImmediate(resolve));
}

function hidden() {
  assert.equal(root.style.display, "none");
  assert.equal(root.children.length, 0);
  assert.deepEqual(sent("pill_hot").at(-1), { rects: [] });
}

function shown() {
  assert.notEqual(root.style.display, "none");
  assert.equal(root.find(".capsule").length, 1);
  mock.timers.tick(420);
  assert.ok(sent("pill_hot").at(-1).rects.length > 0);
}

test("a disabled idle pill starts without content or clickable areas", async (context) => {
  await boot(context);
  hidden();
  assert.ok(sent("pill_hot").every(({ rects }) => rects.length === 0));
});

test("a pill enabled at startup renders and reports its clickable area", async (context) => {
  await boot(context, { ...idle, enabled: true });
  shown();
});

test("an active dictation is visible at startup even when the preference is off", async (context) => {
  await boot(context, { ...idle, phase: "thinking" });
  shown();
});

test("enabling, disabling and enabling again restores the pill", async (context) => {
  await boot(context);
  emit("pill-state", { ...idle, enabled: true });
  shown();
  emit("pill-state", { ...idle });
  hidden();
  emit("pill-state", { ...idle, enabled: true });
  shown();
});

test("active dictation phases remain visible while the preference is off", async (context) => {
  await boot(context);
  for (const phase of ["listening", "locked", "thinking", "copied", "failed", "pastedAgain"]) {
    emit("pill-state", { ...idle, phase });
    shown();
    emit("pill-state", { ...idle });
    hidden();
  }
});

test("a recording, announcement or voice session keeps the disabled pill visible", async (context) => {
  await boot(context);
  for (const activity of [
    { noteStartedAt: Date.now() - 1000 },
    { announcement: { id: 1, icon: "check", tint: "green", text: "Test announcement" } },
    { voice: { phase: "listening", heard: "", answer: "" } },
  ]) {
    emit("pill-state", { ...idle, ...activity });
    shown();
    emit("pill-state", { ...idle });
    hidden();
  }
});

test("hiding the pill clears hitboxes even when old reporting timers fire", async (context) => {
  await boot(context, { ...idle, enabled: true });
  emit("pill-visible", false);
  hidden();
  calls.length = 0;
  mock.timers.tick(420);
  assert.ok(sent("pill_hot").length > 0, "the pending reporting timers ran");
  assert.ok(sent("pill_hot").every(({ rects }) => rects.length === 0));
  emit("pill-bands", [0.5, 0.2]);
  hidden();
  emit("settings-changed", { language: "en" });
  hidden();
  emit("pill-visible", true);
  shown();
});

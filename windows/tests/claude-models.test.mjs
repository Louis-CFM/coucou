import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { Bridge } from "../src/core/bridge.ts";
import { claudeModelControl } from "../src/settings/claude-models.ts";

installFakeDom();
const flush = () => new Promise(resolve => setTimeout(resolve, 0));
const select = control => control.element.find("select")[0];
const ids = control => control.element.find("option").map(option => option.getAttribute("value"));

test("current Claude presets include Sonnet 5.5 and retain a saved older model without an API request", async t => {
  let calls = 0;
  t.mock.method(Bridge, "claudeApiModels", async () => { calls++; return []; });
  const control = claudeModelControl(() => "claude-sonnet-5", async () => { throw new Error("unexpected save"); });
  await control.reload(false);
  assert.ok(ids(control).includes("claude-sonnet-5-5"));
  assert.ok(ids(control).includes("claude-opus-5-5"));
  assert.ok(ids(control).includes("claude-haiku-5-5"));
  assert.equal(select(control).value, "claude-sonnet-5");
  assert.equal(calls, 0);
});

test("API discovery uses its own catalog and never replaces the user's saved model", async t => {
  t.mock.method(Bridge, "chatModels", () => { throw new Error("subscription-aware chat route must not be used"); });
  t.mock.method(Bridge, "claudeApiModels", async () => [{ id: "claude-new", label: "New account model" }]);
  const control = claudeModelControl(() => "custom-gateway-model", async () => { throw new Error("unexpected save"); });
  await control.reload(true);
  assert.deepEqual(ids(control), ["claude-new", "custom-gateway-model"]);
  assert.equal(select(control).value, "custom-gateway-model");
});

test("removing or replacing a key invalidates a late model response", async t => {
  let complete;
  t.mock.method(Bridge, "claudeApiModels", () => new Promise(resolve => { complete = resolve; }));
  let saved = "claude-sonnet-5-5";
  const control = claudeModelControl(() => saved, async next => { saved = next; });
  const loading = control.reload(true);
  await control.reload(false);
  complete([{ id: "stale-private-model", label: "Stale" }]);
  await loading;
  select(control).value = "claude-opus-5-5";
  select(control).fire("change");
  await flush();
  assert.ok(!ids(control).includes("stale-private-model"));
  assert.equal(saved, "claude-opus-5-5");
});

test("failed model saves revert the selection, survive a late list response and allow retry", async t => {
  let complete, calls = 0, fail = true, saved = "claude-sonnet-5";
  t.mock.method(Bridge, "claudeApiModels", () => new Promise(resolve => { complete = resolve; }));
  const control = claudeModelControl(() => saved, async next => {
    calls++;
    await flush();
    if (fail) throw new Error("Settings file is locked");
    saved = next;
  });
  const loading = control.reload(true);
  select(control).value = "claude-sonnet-5-5";
  select(control).fire("change");
  select(control).fire("change");
  assert.equal(select(control).disabled, true);
  await flush(); await flush();
  assert.equal(calls, 1);
  complete([{ id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5" }]);
  await loading;
  assert.match(control.element.textContent, /Settings file is locked/);
  assert.equal(select(control).value, saved);
  fail = false;
  select(control).value = "claude-sonnet-5-5";
  select(control).fire("change");
  await flush(); await flush();
  assert.equal(saved, "claude-sonnet-5-5");
  assert.doesNotMatch(control.element.textContent, /Settings file is locked/);
});

test("catalog failures keep known choices and report the error", async t => {
  t.mock.method(Bridge, "claudeApiModels", async () => { throw new Error("Claude API unavailable"); });
  const control = claudeModelControl(() => "claude-sonnet-5-5", async () => {});
  await control.reload(true);
  assert.match(control.element.textContent, /Claude API unavailable/);
  assert.ok(ids(control).includes("claude-sonnet-5-5"));
  assert.equal(select(control).disabled, false);
});

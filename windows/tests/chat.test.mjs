// The chat view (src/views/chat.ts) on a fake DOM, through the real bridge:
// the model switcher asks for a provider's models only once it is picked and
// has a key, picking saves the settings, and a streamed answer grows in place.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { calls, emit, internals, sent } from "./tauri.mjs";

installFakeDom();
const { buildPrompt } = await import("../src/views/chat.ts");
const { DEFAULT_SETTINGS, State } = await import("../src/core/state.ts");

/** What the mocked Rust side answers, by command. */
let answers;
const plainInvoke = internals.invoke;
internals.invoke = async (cmd, args) => {
  const result = await plainInvoke(cmd, args);
  if (cmd in answers) return typeof answers[cmd] === "function" ? answers[cmd](args) : answers[cmd];
  return result;
};

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

let view;
beforeEach(() => {
  calls.length = 0;
  answers = {};
  State.settings = { ...DEFAULT_SETTINGS, chatModels: {} };
  State.chatHistory = [];
  State.stateOverride = null;
  State.view = "prompt";
  State.droppedFile = null;
  view = buildPrompt(() => {});
  view.sync();
});

const $ = (cls) => view.el.querySelector(cls);
const chips = () => view.el.find(".picker-chip").map((c) => c.textContent);
const models = () => view.el.find(".picker-model").map((m) => m.textContent);

test("the model button shows the active provider's model", () => {
  assert.equal($(".model-name").textContent, "claude-opus-5");
  State.settings = { ...State.settings, chatProvider: "google" };
  view.sync();
  assert.equal($(".model-name").textContent, "gemini-2.0-flash");
  State.settings = { ...State.settings, chatProvider: "ollama" };
  view.sync();
  assert.equal($(".model-name").textContent, "Choose a model");
});

test("a provider without a key is never asked for its models", async () => {
  answers.secret_present = false;
  $(".model-btn").fire("click");
  await flush();
  assert.ok($(".chat-body").classList.contains("picking"));
  assert.deepEqual(chips(), ["Anthropic", "Google", "OpenAI", "OpenRouter", "Codex", "Antigravity"]);
  assert.deepEqual(sent("secret_present"), [{ key: "anthropic-api-key" }]);
  assert.deepEqual(sent("chat_models"), []);
  assert.match($(".picker-status").textContent, /No API key/);
});

test("with a key, the models are listed and picking one saves it", async () => {
  answers.secret_present = true;
  answers.chat_models = [
    { id: "claude-opus-5", label: "Claude Opus 5" },
    { id: "claude-sonnet-5", label: "Claude Sonnet 5" },
  ];
  $(".model-btn").fire("click");
  await flush();
  assert.deepEqual(sent("chat_models"), [{ provider: "anthropic" }]);
  assert.deepEqual(models(), ["Claude Opus 5", "Claude Sonnet 5"]);
  view.el.find(".picker-model")[1].fire("click");
  assert.equal(State.settings.model, "claude-sonnet-5");
  assert.equal(sent("save_settings").at(-1).settings.model, "claude-sonnet-5");
  assert.ok(!$(".chat-body").classList.contains("picking"));
  assert.equal($(".model-name").textContent, "claude-sonnet-5");
});

test("switching provider saves it and asks the new provider only", async () => {
  answers.secret_present = (args) => args.key === "google-api-key";
  answers.chat_models = (args) => (args.provider === "google" ? [{ id: "gemini-2.5-flash", label: "gemini-2.5-flash" }] : []);
  $(".model-btn").fire("click");
  await flush();
  assert.deepEqual(sent("chat_models"), []);
  view.el.find(".picker-chip")[1].fire("click");
  await flush();
  assert.equal(State.settings.chatProvider, "google");
  assert.deepEqual(sent("chat_models"), [{ provider: "google" }]);
  // The saved model was not offered: the flash one is kept instead, and saved.
  assert.equal(State.settings.chatModels.google, "gemini-2.5-flash");
  assert.equal(sent("save_settings").at(-1).settings.chatModels.google, "gemini-2.5-flash");
  assert.deepEqual(models(), ["gemini-2.5-flash"]);
});

test("a local answer streams into one reply, then the finished text replaces it", async () => {
  let finish;
  answers.chat_send = () => new Promise((resolve) => (finish = resolve));
  const input = $(".chat-input");
  input.value = "hello";
  $(".send-btn").fire("click");
  await flush();
  view.sync(); // what State.notify() does in the island
  assert.ok($(".model-btn").disabled, "no switching mid-answer");
  assert.ok($(".typing"), "dots until the first visible text");

  emit("chat-delta", ""); // still thinking
  assert.ok($(".typing"));
  emit("chat-delta", "Hel");
  emit("chat-delta", "Hello **there**");
  view.sync(); // another view update mid-stream must not wipe the live answer
  assert.equal($(".typing"), null);
  const replies = view.el.find(".reply");
  assert.equal(replies.length, 1);
  assert.equal(replies[0].find("STRONG")[0].textContent, "there");

  finish({ text: "Hello **there**!" });
  await flush();
  view.sync();
  assert.equal(view.el.find(".reply").length, 1);
  assert.equal(view.el.find(".reply")[0].textContent, "Hello there!");
  assert.deepEqual(State.chatHistory.map((m) => m.role), ["user", "assistant"]);
  assert.ok(!$(".model-btn").disabled);
});

test("Codex uses the signed-in account without asking for an API key", async () => {
  answers.secret_present = false;
  answers.chat_models = (args) => args.provider === "codex" ? [{ id: "account-model", label: "My Codex model" }] : [];
  $(".model-btn").fire("click");
  await flush();
  const chip = view.el.find(".picker-chip").find((c) => c.textContent === "Codex");
  assert.ok(chip);
  chip.fire("click");
  await flush();
  assert.equal(State.settings.chatProvider, "codex");
  assert.deepEqual(sent("chat_models"), [{ provider: "codex" }]);
  assert.equal(sent("secret_present").length, 1, "only the initial Anthropic provider asked for a key");
  assert.equal(State.settings.chatModels.codex, "account-model");
  assert.deepEqual(models(), ["My Codex model"]);
});

test("Codex login errors stay visible without switching to a paid API provider", async () => {
  State.settings = { ...State.settings, chatProvider: "codex" };
  answers.chat_models = () => { throw new Error("Sign in with codex login"); };
  $(".model-btn").fire("click");
  await flush();
  assert.match($(".picker-status").textContent, /codex login/);
  assert.equal(State.settings.chatProvider, "codex");
  assert.deepEqual(sent("secret_present"), []);
});

test("native CLI permissions are answered explicitly and command text stays plain", async () => {
  await flush();
  emit("agent-request", { id: "req-1", provider: "Codex", kind: "permission", detail: "echo '<script>hi</script>'" });
  const card = $(".cli-request");
  assert.ok(card);
  assert.match(card.textContent, /<script>hi<\/script>/);
  assert.equal(card.find("SCRIPT").length, 0);
  assert.deepEqual(sent("cli_agent_answer"), []);
  card.querySelector(".cli-allow").fire("click");
  await flush();
  assert.deepEqual(sent("cli_agent_answer"), [{ id: "req-1", answer: { allow: true, answers: {} } }]);
  assert.equal($(".cli-request"), null);
});

test("CLI questions retain their ids and answers, and expired cards disappear", async () => {
  await flush();
  emit("agent-request", { id: "req-2", provider: "Codex", kind: "question", detail: "", questions: [{ id: "destination", question: "Where should it go?" }] });
  $(".cli-request").querySelector(".chat-input").value = "/tmp/my-project";
  $(".cli-allow").fire("click");
  await flush();
  assert.deepEqual(sent("cli_agent_answer")[0], { id: "req-2", answer: { allow: true, answers: { destination: ["/tmp/my-project"] } } });
  emit("agent-request", { id: "req-3", provider: "Codex", kind: "permission", detail: "write" });
  emit("agent-request-ended", { id: "req-3" });
  assert.equal($(".cli-request"), null);
});

test("Antigravity selects models from its signed-in CLI account", async () => {
  State.settings = { ...State.settings, chatProvider: "antigravity" };
  answers.chat_models = [{ id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6 (Thinking)" }];
  $(".model-btn").fire("click");
  await flush();
  assert.deepEqual(sent("secret_present"), []);
  assert.deepEqual(sent("chat_models"), [{ provider: "antigravity" }]);
  assert.equal(State.settings.chatModels.antigravity, "claude-sonnet-4-6");
});

test("a CLI turn can be stopped without showing a failure screen", async () => {
  State.settings = { ...State.settings, chatProvider: "codex" };
  let reject;
  answers.chat_send = () => new Promise((_, no) => (reject = no));
  $(".chat-input").value = "run this task";
  $(".send-btn").fire("click");
  await flush();
  view.sync();
  assert.equal($(".send-btn").title, "Stop");
  $(".send-btn").fire("click");
  await flush();
  assert.equal(sent("chat_cancel").length, 1);
  reject(new Error("The CLI request was cancelled."));
  await flush();
  assert.equal(State.view, "prompt");
});

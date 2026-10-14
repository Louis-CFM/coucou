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
  State.mode = "expanded";
  State.chatPickerOpen = false;
  State.droppedFile = null;
  view = buildPrompt(() => {});
  view.sync();
});

const $ = (cls) => view.el.querySelector(cls);
const chips = () => view.el.find(".picker-chip").map((c) => c.textContent);
const models = () => view.el.find(".picker-model").map((m) => m.textContent);

test("leaving chat closes the selector even without syncing the inactive view", async () => {
  answers.secret_present = false;
  $(".model-btn").fire("click");
  await flush();
  assert.equal(State.chatPickerOpen, true);
  State.view = "overview";
  State.notify();
  assert.equal(State.chatPickerOpen, false);
  assert.ok(!$(".chat-body").classList.contains("picking"));
  State.view = "prompt";
  State.notify();
  assert.equal(State.chatPickerOpen, false);
});

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
  assert.deepEqual(chips(), ["Anthropic", "Google", "OpenAI", "OpenRouter", "Codex CLI"]);
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

test("Codex uses the existing model button without an API key and saves effort and speed", async () => {
  State.settings = {...State.settings, chatProvider: "codex", chatModels: {codex: "gpt-test"}};
  answers.codex_models = [{id: "gpt-test", label: "GPT Test", reasoningEfforts: ["low", "high"], defaultEffort: "low", serviceTiers: [{id: "priority",name: "Fast",description: "Faster"}],isDefault: true},
    {id: "gpt-other",label: "GPT Other",reasoningEfforts: ["medium"],defaultEffort: "medium",serviceTiers: []}];
  view.sync();$(".model-btn").fire("click");await flush();
  assert.equal(sent("secret_present").length,0);
  assert.equal(sent("codex_models").length,1);
  assert.equal(State.settings.codexReasoningEffort,"low");
  const slider=$(".codex-effort-slider");slider.value="1";slider.fire("input");slider.fire("change");
  assert.equal(State.settings.codexReasoningEffort,"high");
  $(".codex-bolt").fire("click");
  assert.equal(State.settings.codexServiceTier,"priority");
  assert.equal(sent("save_settings").at(-1).settings.codexServiceTier,"priority");
  $(".codex-model-link").fire("click");
  assert.ok($(".picker").classList.contains("codex-models-mode"));
  view.el.find(".picker-model")[1].fire("click");
  assert.ok(!$(".picker").classList.contains("codex-models-mode"));
  assert.equal(State.settings.chatModels.codex,"gpt-other");
  assert.equal(State.settings.codexReasoningEffort,"medium");
  assert.equal(State.settings.codexServiceTier,"");
  assert.ok($(".chat-body").classList.contains("picking"));
});

test("Codex stop button sends cancellation without submitting another turn", async () => {
  State.settings={...State.settings,chatProvider:"codex"};
  let finish;answers.chat_send=()=>new Promise((resolve)=>finish=resolve);
  $(".chat-input").value="test";$(".send-btn").fire("click");await flush();
  $(".send-btn").fire("click");await flush();
  assert.equal(sent("chat_send").length,1);assert.equal(sent("chat_cancel").length,1);
  finish({text:"done"});await flush();
});

test("a new chat discards a late Codex reply and its streamed messages", async () => {
  State.view="prompt";
  State.settings={...State.settings,chatProvider:"codex"};
  let finish;answers.chat_send=()=>new Promise(resolve=>finish=resolve);
  $(".chat-input").value="old question";$(".send-btn").fire("click");await flush();
  State.chatHistory=[];view.sync();emit("chat-delta","old reply");
  assert.equal(view.el.find(".reply").length,0);
  finish({text:"old completed reply"});await flush();
  assert.deepEqual(State.chatHistory,[]);assert.equal(State.view,"prompt");
});

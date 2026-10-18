import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { registerVoiceHandlers } from "../src/island/voice.ts";

registerVoiceHandlers();
beforeEach(() => {
  calls.length = 0;
  State.tasks = [];
  State.focusId = null;
  State.settings = { ...DEFAULT_SETTINGS, chatProvider: "codex" };
});

test("calling a pet brings it into view even before a CLI hook has created its pill", () => {
  emit("voice-pet", "antigravity");
  assert.equal(State.focusId, "agent_antigravity");
  assert.equal(State.tasks.filter((task) => task.id === "agent_antigravity").length, 1);
  emit("voice-pet", "antigravity");
  assert.equal(State.tasks.filter((task) => task.id === "agent_antigravity").length, 1);
  emit("voice-pet", "codex");
  assert.equal(State.focusId, "agent_codex");
  assert.equal(State.settings.chatProvider, "codex");
  assert.deepEqual(sent("save_settings"), []);
});

test("Gemini and Claude voice sessions have their own visible pets; unknown routes do nothing", () => {
  emit("voice-pet", "gemini-cli");
  assert.equal(State.focusId, "agent_gemini");
  emit("voice-pet", "claude-cli");
  assert.equal(State.focusId, "integration_claude");
  emit("voice-pet", "unknown");
  assert.equal(State.tasks.length, 2);
});

test("the existing local Ollama pet also owns its continuous voice conversation", () => {
  emit("voice-pet", "ollama");
  assert.equal(State.focusId, "ai_ollama");
  assert.equal(State.settings.chatProvider, "codex");
  assert.deepEqual(sent("save_settings"), []);
});

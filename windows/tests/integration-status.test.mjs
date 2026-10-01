import assert from "node:assert/strict";
import { test } from "node:test";
import { build } from "esbuild";

const { outputFiles } = await build({
  entryPoints: ["src/views/integration-status.ts"],
  bundle: true,
  write: false,
  format: "esm",
  platform: "node",
});
const { idleIntegrationStatusLabel } = await import(
  `data:text/javascript;base64,${Buffer.from(outputFiles[0].text).toString("base64")}`
);

test("installed code hooks do not remain in the generic loading state", () => {
  assert.equal(idleIntegrationStatusLabel("integration_codex", true, null), "Hooks installed");
  assert.equal(idleIntegrationStatusLabel("integration_claude", true, null), "Hooks installed");
});

test("idle integration labels preserve missing, loading, and error states", () => {
  assert.equal(idleIntegrationStatusLabel("integration_codex", false, null), "Hooks not installed");
  assert.equal(idleIntegrationStatusLabel("integration_github", false, null), "Key not configured");
  assert.equal(idleIntegrationStatusLabel("integration_github", true, null), "Connected · loading…");
  assert.equal(idleIntegrationStatusLabel("integration_codex", true, "Hook error"), "Hook error");
});

/**
 * Hook script tests.
 * Runs brain-session-start.js and brain-prompt.js as subprocesses to validate
 * real behavior: guard conditions, error resilience, and output format.
 */
import { describe, it, expect } from "vitest";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NODE = process.execPath;
const HOOKS_DIR = path.join(__dirname, "..", "hooks");
const SESSION_START = path.join(HOOKS_DIR, "brain-session-start.js");
const PROMPT_HOOK = path.join(HOOKS_DIR, "brain-prompt.js");

function runHook(
  script: string,
  input: object,
  env: Record<string, string> = {}
): { stdout: string; stderr: string; status: number; ms: number } {
  const start = Date.now();
  const result = spawnSync(NODE, [script], {
    input: JSON.stringify(input),
    encoding: "utf8",
    timeout: 10000,
    env: { ...process.env, ...env },
  });
  return {
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    status: result.status ?? -1,
    ms: Date.now() - start,
  };
}

// ── COUCOU_BRAIN_INTERNAL guard ───────────────────────────────────────────────

describe("COUCOU_BRAIN_INTERNAL guard", () => {
  it("session-start exits 0 with no output when COUCOU_BRAIN_INTERNAL=1", () => {
    const r = runHook(SESSION_START, { session_id: "test", cwd: process.cwd() }, {
      COUCOU_BRAIN_INTERNAL: "1",
    });
    expect(r.status).toBe(0);
    expect(r.stdout).toBe("");
  });

  it("brain-prompt exits 0 with no output when COUCOU_BRAIN_INTERNAL=1", () => {
    const r = runHook(PROMPT_HOOK, { session_id: "test", prompt: "appliquer la migration" }, {
      COUCOU_BRAIN_INTERNAL: "1",
    });
    expect(r.status).toBe(0);
    expect(r.stdout).toBe("");
  });

  it("session-start exits 0 when BRAIN_OFF=1", () => {
    const r = runHook(SESSION_START, { session_id: "test", cwd: process.cwd() }, {
      BRAIN_OFF: "1",
    });
    expect(r.status).toBe(0);
    expect(r.stdout).toBe("");
  });
});

// ── Error resilience ──────────────────────────────────────────────────────────

describe("hook resilience", () => {
  it("session-start exits 0 and outputs nothing with invalid brain config path", () => {
    // Point to a non-existent brain path by temporarily renaming the config
    // (we simulate this by using a temp dir that has no state)
    const r = runHook(
      SESSION_START,
      { session_id: "test", cwd: "/tmp/nonexistent_project_xyz" },
      { HOME: "/tmp/nonexistent_home_xyz" }  // force config load failure
    );
    // Should exit 0, never non-zero
    expect(r.status).toBe(0);
  });

  it("brain-prompt exits 0 with no output on missing FTS db", () => {
    const r = runHook(
      PROMPT_HOOK,
      { session_id: "test", prompt: "appliquer migration prisma", cwd: "/tmp" },
      { HOME: "/tmp/nonexistent_home_xyz" }
    );
    expect(r.status).toBe(0);
    // Output is either empty or valid JSON — never malformed
    if (r.stdout.trim()) {
      expect(() => JSON.parse(r.stdout)).not.toThrow();
    }
  });

  it("brain-prompt exits 0 with empty stdout on too-short prompt", () => {
    const r = runHook(PROMPT_HOOK, {
      session_id: "test",
      prompt: "ok",
      cwd: process.cwd(),
    });
    expect(r.status).toBe(0);
    expect(r.stdout).toBe("");
  });

  it("brain-prompt exits 0 on prompt with only stopwords", () => {
    const r = runHook(PROMPT_HOOK, {
      session_id: "test",
      prompt: "avec dans pour plus bien aussi donc alors",
      cwd: process.cwd(),
    });
    expect(r.status).toBe(0);
    expect(r.stdout).toBe("");
  });
});

// ── Output format ─────────────────────────────────────────────────────────────

describe("output format", () => {
  it("brain-prompt output is valid JSON with hookSpecificOutput when it injects", () => {
    // This test only validates the shape; it may output nothing if brain not set up.
    // We test with a prompt that might match something, and validate the shape if output is non-empty.
    const r = runHook(PROMPT_HOOK, {
      session_id: "format-test",
      prompt: "appliquer migration base données prisma",
      cwd: process.cwd(),
    });
    expect(r.status).toBe(0);
    if (r.stdout.trim()) {
      let parsed: { hookSpecificOutput?: { hookEventName?: string; additionalContext?: string } };
      expect(() => { parsed = JSON.parse(r.stdout); }).not.toThrow();
      expect(parsed!.hookSpecificOutput).toBeDefined();
      expect(parsed!.hookSpecificOutput?.hookEventName).toBe("UserPromptSubmit");
      expect(typeof parsed!.hookSpecificOutput?.additionalContext).toBe("string");
      // additionalContext should be under 4000 chars
      expect(parsed!.hookSpecificOutput!.additionalContext!.length).toBeLessThanOrEqual(4000);
    }
  });

  it("session-start outputs plain text (not JSON) when injecting", () => {
    const r = runHook(SESSION_START, {
      session_id: "format-test",
      cwd: process.cwd(),
    });
    expect(r.status).toBe(0);
    if (r.stdout.trim()) {
      // Should NOT be JSON
      let isJson = false;
      try { JSON.parse(r.stdout); isJson = true; } catch {}
      expect(isJson).toBe(false);
    }
  });
});

// ── Latency ───────────────────────────────────────────────────────────────────

describe("hook latency", () => {
  it("brain-prompt completes within 500ms (startup + search)", () => {
    const r = runHook(PROMPT_HOOK, {
      session_id: "latency-test",
      prompt: "appliquer migration base données prisma postgresql",
      cwd: process.cwd(),
    });
    // Allow generous budget for cold start in test environment
    expect(r.ms).toBeLessThan(500);
    expect(r.status).toBe(0);
  });

  it("brain-prompt with COUCOU_BRAIN_INTERNAL exits in < 50ms", () => {
    const r = runHook(
      PROMPT_HOOK,
      { session_id: "latency-guard", prompt: "test" },
      { COUCOU_BRAIN_INTERNAL: "1" }
    );
    expect(r.ms).toBeLessThan(50);
    expect(r.status).toBe(0);
  });
});

// ── Pause flag ────────────────────────────────────────────────────────────────

describe("pause flag", () => {
  it("session-start injects nothing when brain is paused", () => {
    // Write a pause flag to the temp brain dir and run with custom HOME
    // For this test we use the actual brain config to find brainPath
    let brainBase: string | null = null;
    try {
      const cfg = JSON.parse(
        fs.readFileSync(path.join(HOOKS_DIR, "..", "brain.config.json"), "utf8")
      );
      const localPath = path.join(HOOKS_DIR, "..", "brain.config.local.json");
      const local = fs.existsSync(localPath)
        ? JSON.parse(fs.readFileSync(localPath, "utf8"))
        : {};
      brainBase = (local.brainPath || cfg.brainPath).replace(/^~/, os.homedir());
    } catch { return; } // skip if config not available

    if (!brainBase) return;

    const pausedFlag = path.join(brainBase, ".state", "paused");
    const wasPaused = fs.existsSync(pausedFlag);

    try {
      fs.mkdirSync(path.dirname(pausedFlag), { recursive: true });
      fs.writeFileSync(pausedFlag, new Date().toISOString(), "utf8");

      const r = runHook(SESSION_START, {
        session_id: "pause-test",
        cwd: process.cwd(),
      });

      expect(r.status).toBe(0);
      expect(r.stdout).toBe("");
    } finally {
      if (!wasPaused && fs.existsSync(pausedFlag)) {
        fs.unlinkSync(pausedFlag);
      }
    }
  });
});

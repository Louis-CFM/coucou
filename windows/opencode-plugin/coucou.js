// coucou.js — Coucou plugin for opencode.
//
// Forwards opencode session / tool / permission events to Coucou over the
// named pipe `\\.\pipe\coucou-<sid>` via `coucou-hook.exe`, the same relay
// Claude Code hooks use. Payloads reuse the Claude Code hook shape
// (`hook_event_name`, `session_id`, `cwd`, `tool_name`, `tool_input`, …)
// plus `"agent": "opencode"`, so the island routes them to the opencode pill.
//
// Hard rule (same as nb-hook / coucou-hook): **never block opencode.**
//   * Fire-and-forget events get a 2 s relay budget and are abandoned after.
//   * Only `permission.asked` waits (up to 110 s) for the island's decision.
//     No answer — Coucou closed, timeout, relay missing — resolves to
//     "ask", and opencode asks in the TUI exactly as if Coucou were absent.
//
// Install: copied to `~/.config/opencode/plugins/coucou.js` by Coucou's
// settings window (or manually). No `opencode.json` edit is needed:
// files in the global plugin directory are auto-loaded at startup.
//
// Version stamp — the Tauri installer compares this to detect outdated copies.
// Bump on any protocol change.
// COUCOU_PLUGIN_VERSION is matched by src-tauri/src/opencode.rs (do not rename).
const COUCOU_PLUGIN_VERSION = 1;

// ── Relay resolution ──────────────────────────────────────────────────────────

function relayCandidates() {
  const list = [];
  try {
    const local = typeof process !== "undefined" ? process.env.LOCALAPPDATA : "";
    if (local) list.push(`${local}\\Coucou\\bin\\coucou-hook.exe`);
  } catch { /* process.env unavailable — fall through */ }
  return list;
}

/** stdin bytes for the relay: JSON line, like the Claude Code hook payload. */
function line(obj) {
  return `${JSON.stringify(obj)}\n`;
}

/**
 * Spawn the relay synchronously with `input` on stdin.
 * Returns trimmed stdout ("" when the relay is missing, crashed or timed out).
 * Never throws — silence is the safe answer.
 */
async function relay(event, payload, timeoutMs, $) {
  const candidates = relayCandidates();
  if (candidates.length === 0) return "";
  const body = line({ ...payload, hook_event_name: event, agent: "opencode" });

  // Prefer opencode's Bun shell API ($), fall back to node child_process.
  try {
    if ($) {
      const proc = $`${candidates[0]} ${event}`.stdin(body);
      const done = await Promise.race([
        proc.then((r) => (typeof r === "string" ? r : r?.stdout ?? "")),
        new Promise((resolve) => setTimeout(() => resolve(""), timeoutMs)),
      ]);
      return String(done ?? "").trim();
    }
  } catch { /* fall through to spawnSync */ }

  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { spawnSync } = require("node:child_process");
    const res = spawnSync(candidates[0], [event], {
      input: body,
      encoding: "utf8",
      timeout: timeoutMs,
      windowsHide: true,
    });
    return String(res.stdout ?? "").trim();
  } catch {
    return "";
  }
}

function fireAndForget(event, payload, $) {
  // Deliberately unawaited: the 2 s budget lives inside the relay call chain
  // via timeout, and nothing here may delay the agent.
  void relay(event, payload, 2000, $).catch(() => {});
}

// ── Payload helpers (defensive: event shapes vary across opencode versions) ──

function pick(obj, paths) {
  for (const p of paths) {
    const v = p.split(".").reduce((o, k) => (o == null ? o : o[k]), obj);
    if (typeof v === "string" && v) return v;
    if (typeof v === "number") return String(v);
  }
  return "";
}

function sessionIdOf(input, fallback) {
  return (
    pick(input, ["sessionID", "session.id", "sessionId", "id"]) ||
    fallback ||
    "unknown"
  );
}

// ── Decision translation ─────────────────────────────────────────────────────

/**
 * coucou-hook.exe answers PermissionRequest with Claude-shaped JSON:
 * {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny"}}}
 * Map it back to what opencode's `permission.asked` understands.
 * Returns "allow" | "deny" | null (null = no usable answer → ask in TUI).
 */
function translateDecision(stdout) {
  if (!stdout) return null;
  const lower = stdout.toLowerCase();
  if (lower === "allow" || lower === "deny") return lower;
  try {
    const parsed = JSON.parse(stdout);
    const behavior = parsed?.hookSpecificOutput?.decision?.behavior;
    if (behavior === "allow" || behavior === "deny") return behavior;
    if (parsed?.behavior === "allow" || parsed?.behavior === "deny") return parsed.behavior;
    if (parsed?.decision === "allow" || parsed?.decision === "deny") return parsed.decision;
  } catch { /* not JSON — fall through */ }
  return null;
}

// ── Plugin ────────────────────────────────────────────────────────────────────

export const CoucouPlugin = async ({ $, directory }) => {
  const cwd = directory || (typeof process !== "undefined" ? process.cwd() : "");

  /** Base payload shared by every event. */
  const base = (extra = {}) => ({ cwd, ...extra });

  return {
    // ── Sessions ────────────────────────────────────────────────────────────
    "session.created": async (input) => {
      fireAndForget("SessionStart", base({ session_id: sessionIdOf(input, "") }), $);
    },
    "session.idle": async (input) => {
      const message = pick(input, ["message", "summary", "title"]);
      fireAndForget("Stop", base({ session_id: sessionIdOf(input, ""), message }), $);
    },
    "session.error": async (input) => {
      const message = pick(input, ["error.message", "message", "error"]);
      fireAndForget("StopFailure", base({ session_id: sessionIdOf(input, ""), message }), $);
    },
    "session.deleted": async (input) => {
      fireAndForget("SessionEnd", base({ session_id: sessionIdOf(input, "") }), $);
    },

    // User prompt submitted in a session → thinking state + step line.
    "message.updated": async (input) => {
      const role = pick(input, ["message.role", "role"]);
      if (role && role !== "user") return;
      const prompt = pick(input, ["message.content", "message.text", "content", "text", "prompt"]);
      if (!prompt) return;
      fireAndForget(
        "UserPromptSubmit",
        base({ session_id: sessionIdOf(input, ""), prompt: prompt.slice(0, 2000) }),
        $,
      );
    },

    // ── Tools ───────────────────────────────────────────────────────────────
    "tool.execute.before": async (input, output) => {
      const tool = pick(input, ["tool", "toolName", "name"]) || "Tool";
      const args =
        (output && typeof output.args === "object" && output.args) ||
        input.args ||
        input.input ||
        {};
      // The question tool surfaces as an island question card.
      if (tool.toLowerCase() === "question") {
        const q = pick({ args }, ["args.question", "args.prompt", "args.text"]) || "opencode asks a question";
        fireAndForget(
          "Notification",
          base({ session_id: sessionIdOf(input, ""), message: `${q}?` }),
          $,
        );
        return;
      }
      fireAndForget(
        "PreToolUse",
        base({ session_id: sessionIdOf(input, ""), tool_name: tool, tool_input: args }),
        $,
      );
    },
    "tool.execute.after": async (input, output) => {
      const failed = Boolean(output?.error || input?.error);
      fireAndForget(
        failed ? "PostToolUseFailure" : "PostToolUse",
        base({ session_id: sessionIdOf(input, "") }),
        $,
      );
    },

    // ── Permission (the only blocking hook) ─────────────────────────────────
    "permission.asked": async (input, output) => {
      const tool = pick(input, ["tool", "toolName", "permission", "name"]) || "Tool";
      const args =
        (output && typeof output.args === "object" && output.args) ||
        input.args ||
        input.input ||
        {};
      const suggestions = input.suggestions || input.patterns || [];

      const stdout = await relay(
        "PermissionRequest",
        base({
          session_id: sessionIdOf(input, ""),
          tool_name: tool,
          tool_input: args,
          permission_suggestions: suggestions,
        }),
        110_000,
        $,
      ).catch(() => "");
      const decision = translateDecision(stdout);

      // No answer (Coucou closed / timeout): fall through silently so opencode
      // asks in the TUI — exactly the "ask" behaviour.
      if (!decision) return;

      // Try every known resolver shape; unknown shapes are ignored rather
      // than throwing, because throwing inside a permission hook denies the
      // tool and must never happen by accident.
      try {
        if (output && typeof output === "object") {
          if ("decision" in output || "behavior" in output) {
            if ("decision" in output) output.decision = decision;
            if ("behavior" in output) output.behavior = decision;
            return;
          }
        }
      } catch { /* notification-only fallback */ }
      // Returning the bare word covers resolvers that use the return value.
      // Resolvers that ignore it simply ask in the TUI — still correct.
      return decision;
    },
    "permission.replied": async (input) => {
      // The user answered in the TUI (island unreachable or too slow):
      // clear a stale approval card so it stops lying.
      const replied = pick(input, ["decision", "reply", "behavior"]);
      if (replied) {
        fireAndForget("PostToolUse", base({ session_id: sessionIdOf(input, "") }), $);
      }
    },
  };
};

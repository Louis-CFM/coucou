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
const COUCOU_PLUGIN_VERSION = 2;

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

/**
 * The best one-line summary a lifecycle event can give, or `{}` when it has
 * none.
 *
 * `pick` only yields strings and numbers, so an error object has to be
 * unwrapped by hand: the SDK puts the human-readable text on
 * `error.data.message`, never on `error` itself, so `pick(props, ["error"])`
 * returns "" and the failure reaches the island with no explanation.
 */
function eventMessage(props) {
  const err = props.error;
  if (err && typeof err === "object") {
    const text = pick(err, ["data.message", "message"]);
    if (text) return { message: text };
  }
  const message = pick(props, ["message", "summary", "title", "error.message"]);
  return message ? { message } : {};
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

  // Session and permission lifecycle events are NOT hook keys. opencode only
  // invokes the keys declared in the Hooks interface — `tool.execute.*`,
  // `chat.*`, `permission.ask`, `command.execute.before`, `shell.env` and the
  // rest. Everything else arrives through the single `event` hook and has to be
  // dispatched here by `event.type`. Registering `session.created` and friends
  // as top-level keys looks right and is silently never called.
  const EVENT_MAP = {
    "session.created": "SessionStart",
    "session.idle": "Stop",
    "session.error": "StopFailure",
    "session.deleted": "SessionEnd",
  };

  return {
    // ── Lifecycle, via the one hook that actually fires ─────────────────────
    event: async ({ event }) => {
      const props = event.properties || {};
      const info = props.info || {};
      const session_id = sessionIdOf(props, "") || sessionIdOf(info, "");

      const name = EVENT_MAP[event.type];
      if (name) {
        fireAndForget(name, base({ session_id, ...eventMessage(props) }), $);
        return;
      }

      // The user answered in the TUI (island unreachable or too slow):
      // clear a stale approval card so it stops lying.
      if (event.type === "permission.replied") {
        fireAndForget("PostToolUse", base({ session_id }), $);
      }
    },

    // The prompt text is not on the message. `UserMessage` carries only
    // role/agent/model — the text lives in its parts. `message.updated` hands
    // over `properties.info`, a Message, so reading text off it finds nothing
    // and that event could never have carried a prompt. `chat.message` is the
    // hook that is given the parts.
    "chat.message": async (input, output) => {
      const parts = Array.isArray(output?.parts) ? output.parts : [];
      const text = parts
        .filter((p) => p && p.type === "text" && typeof p.text === "string" && p.text)
        .map((p) => p.text)
        .join("\n")
        .trim();
      if (!text) return;
      const session_id =
        pick(input, ["sessionID"]) || pick(output?.message || {}, ["id"]) || "";
      fireAndForget("UserPromptSubmit", base({ session_id, prompt: text.slice(0, 2000) }), $);
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
    // The key is `permission.ask`, per the Hooks interface — there is no
    // `permission.asked`. Signature: (input: Permission, output: { status }).
    "permission.ask": async (input, output) => {
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

      // The Hooks interface types this as `output.status: "ask" | "deny" |
      // "allow"` — there is no `decision` or `behavior` field to write. Assign
      // only that, and only when it is actually present: touching anything else
      // here risks denying a tool, which must never happen by accident.
      try {
        if (output && typeof output === "object" && "status" in output) {
          output.status = decision;
        }
      } catch { /* notification-only fallback */ }
      // Returning the bare word covers resolvers that use the return value.
      // Resolvers that ignore it simply ask in the TUI — still correct.
      return decision;
    },
  };
};

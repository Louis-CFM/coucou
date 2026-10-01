// Coucou plugin for opencode — forwards session/tool events to the Coucou
// island on Windows via the same named pipe coucou-hook.exe uses.
//
// Install:
//   1. Copy this file to ~/.config/opencode/plugins/coucou.ts
//      (or <project>/.opencode/plugins/coucou.ts for project-only)
//   2. Restart opencode. No config needed — fire-and-forget, never blocks.
//
// How it works:
// - opencode plugins receive typed events (session.created, tool.execute.before,
//   etc.). We normalize them to the Claude-like names the island already
//   understands (SessionStart, PreToolUse, PostToolUse, Stop, SessionEnd)
//   and write one JSON line per event to \\.\pipe\coucou-<sid>.
// - If Coucou is closed the pipe doesn't exist — we swallow the error and the
//   session continues untouched (same rule as coucou-hook: never block).
// - Approvals (permission.asked) are reported as activity only. Blocking
//   approval from the island is Claude-only for now.

import type { Plugin } from "@opencode-ai/plugin";
import * as net from "node:net";
import * as os from "node:os";

function pipeName(): string {
  // Must match pipe::pipe_name() in src-tauri/src/pipe.rs:
  // \\.\pipe\coucou-<sid>, fallback USERNAME.
  // SID lookup from Node is overkill — USERNAME fallback matches the Rust
  // fallback path and works for single-user machines. If you run multi-user,
  // set COUCOU_PIPE explicitly.
  if (process.env.COUCOU_PIPE) return process.env.COUCOU_PIPE;
  const user = process.env.USERNAME || process.env.USER || "user";
  return `\\\\.\\pipe\\coucou-${user}`;
}

function send(payload: Record<string, unknown>) {
  try {
    const line = JSON.stringify({ source: "opencode", ...payload }) + "\n";
    const client = net.createConnection(pipeName());
    let settled = false;
    const done = () => {
      if (!settled) {
        settled = true;
        try { client.destroy(); } catch { /* noop */ }
      }
    };
    client.on("error", done);
    client.on("connect", () => {
      client.write(line, () => done());
    });
    // Never hold the session: 300ms like coucou-hook's CONNECT_TIMEOUT.
    setTimeout(done, 300).unref?.();
  } catch {
    // Never block opencode.
  }
}

function cwdOf(input: any): string {
  return input?.session?.directory ?? input?.directory ?? process.cwd?.() ?? "";
}

export const CoucouPlugin: Plugin = async (_ctx) => {
  return {
    "session.created": async (input: any) => {
      send({
        hook_event_name: "SessionStart",
        session_id: input?.session?.id ?? input?.sessionID ?? "unknown",
        cwd: cwdOf(input),
      });
    },
    "session.deleted": async (input: any) => {
      send({
        hook_event_name: "SessionEnd",
        session_id: input?.session?.id ?? input?.sessionID ?? "unknown",
        cwd: cwdOf(input),
      });
    },
    "session.idle": async (input: any) => {
      send({
        hook_event_name: "Stop",
        session_id: input?.session?.id ?? input?.sessionID ?? "unknown",
        cwd: cwdOf(input),
        message: "opencode idle",
      });
    },
    "session.error": async (input: any) => {
      send({
        hook_event_name: "StopFailure",
        session_id: input?.session?.id ?? "unknown",
        cwd: cwdOf(input),
        message: String(input?.error ?? input?.message ?? "error").slice(0, 200),
      });
    },
    "tool.execute.before": async (input: any) => {
      const tool = input?.tool ?? input?.toolName ?? "Tool";
      send({
        hook_event_name: "PreToolUse",
        session_id: input?.session?.id ?? input?.sessionID ?? "unknown",
        cwd: cwdOf(input),
        tool_name: String(tool),
        tool_input: {
          command: input?.args?.command ?? input?.input?.command,
          file_path: input?.args?.file ?? input?.args?.path ?? input?.input?.file_path,
          path: input?.args?.path ?? input?.input?.path,
          query: input?.args?.query ?? input?.input?.query,
        },
      });
    },
    "tool.execute.after": async (input: any) => {
      send({
        hook_event_name: input?.error ? "PostToolUseFailure" : "PostToolUse",
        session_id: input?.session?.id ?? input?.sessionID ?? "unknown",
        cwd: cwdOf(input),
        tool_name: String(input?.tool ?? input?.toolName ?? "Tool"),
      });
    },
    "permission.asked": async (input: any) => {
      // Fire-and-forget activity (no blocking approval yet).
      send({
        hook_event_name: "PreToolUse",
        session_id: input?.session?.id ?? "unknown",
        cwd: cwdOf(input),
        tool_name: String(input?.tool ?? "Tool"),
        tool_input: { command: String(input?.action ?? input?.request ?? "").slice(0, 200) },
      });
    },
  };
};

export default CoucouPlugin;

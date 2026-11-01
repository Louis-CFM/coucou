import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createReporter } from "../shared/session.ts";

/** Pi 1.3: settlement follows retries, compaction and queued continuations. */
export default function coucou(pi: ExtensionAPI): void {
  const reporter = createReporter("pi");
  let outcome: "completed" | "aborted" | "error" = "completed";

  pi.on("session_start", (_event, ctx) => { reporter.start(ctx); });
  pi.on("before_agent_start", (_event, ctx) => {
    reporter.send(ctx, { hook_event_name: "UserPromptSubmit" });
  });
  pi.on("agent_start", () => { outcome = "completed"; });
  pi.on("tool_execution_start", (event, ctx) => {
    reporter.send(ctx, { hook_event_name: "PreToolUse", tool_name: event.toolName });
  });
  pi.on("tool_execution_end", (event, ctx) => {
    reporter.send(ctx, {
      hook_event_name: event.isError ? "PostToolUseFailure" : "PostToolUse",
      tool_name: event.toolName,
    });
  });
  pi.on("agent_before_settle", event => { outcome = event.outcome; });
  pi.on("agent_settled", (event, ctx) => {
    reporter.send(ctx, {
      hook_event_name: event.aborted || outcome === "aborted" ? "Interrupt"
        : outcome === "error" ? "StopFailure" : "Stop",
    });
  });
  pi.on("session_shutdown", () => reporter.close());
}
